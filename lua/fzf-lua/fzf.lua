-- slimmed down version of nvim-fzf's 'raw_fzf', changes include:
-- DOES NOT SUPPORT WINDOWS
-- does not close the pipe before all writes are complete
-- option to not add '\n' on content function callbacks
-- https://github.com/vijaymarupudi/nvim-fzf/blob/master/lua/fzf.lua
local uv = vim.loop

local utils = require "fzf-lua.utils"
local libuv = require "fzf-lua.libuv"

local M = {}

-- workaround to a potential 'tempname' bug? (#222)
-- neovim doesn't guarantee the existence of the
-- parent temp dir potentially failing `mkfifo`
-- https://github.com/neovim/neovim/issues/1432
-- https://github.com/neovim/neovim/pull/11284
local function tempname()
  local tmpname = vim.fn.tempname()
  local parent = vim.fn.fnamemodify(tmpname, ":h")
  -- parent must exist for `mkfifo` to succeed
  -- if the neovim temp dir was deleted or the
  -- tempname already exists, we use 'os.tmpname'
  if not uv.fs_stat(parent) or uv.fs_stat(tmpname) then
    tmpname = os.tmpname()
    -- 'os.tmpname' touches the file which
    -- will also fail `mkfifo`, delete it
    vim.fn.delete(tmpname)
  end
  return tmpname
end

-- contents can be either a table with tostring()able items, or a function that
-- can be called repeatedly for values. The latter can use coroutines for async
-- behavior.
---@param contents string[]|table|function?
---@param fzf_cli_args string[]
---@param opts table
---@return table selected
---@return integer exit_code
function M.raw_fzf(contents, fzf_cli_args, opts)
  if not coroutine.running() then
    error("[Fzf-lua] function must be called inside a coroutine.")
  end

  if not opts then opts = {} end
  local cwd = opts.fzf_cwd or opts.cwd
  local cmd = { opts.fzf_bin or "fzf" }
  local fifotmpname = utils.__IS_WINDOWS and utils.windows_pipename() or tempname()
  local outputtmpname = tempname()

  -- we use a temporary env $FZF_DEFAULT_COMMAND instead of piping
  -- the command to fzf, this way fzf kills the command when it exits.
  -- This is especially important with our shell helper as io.write fails
  -- to select when the pipe is broken (EPIPE) so the neovim headless
  -- instance never terminates which hangs fzf on exit
  local FZF_DEFAULT_COMMAND = nil

  utils.tbl_extend(cmd, fzf_cli_args or {})
  if type(opts.fzf_cli_args) == "table" then
    utils.tbl_extend(cmd, opts.fzf_cli_args)
  elseif type(opts.fzf_cli_args) == "string" then
    utils.tbl_extend(cmd, { opts.fzf_cli_args })
  end

  if contents then
    if type(contents) == "string" and #contents > 0 then
      if opts.silent_fail ~= false then
        contents = contents .. " || " .. utils.shell_nop()
      end
      FZF_DEFAULT_COMMAND = contents
    else
      -- Note: for some unknown reason, even though 'termopen' cmd is wrapped with
      -- `sh -c`, on rare occasions (or unique systems?) when using `fish` shell,
      -- commands that use the input redirection will hang indefintely (#633)
      -- Using `cat` instead to read from the FIFO named pipe seems to solve it,
      -- this is also better as it lets fzf handle spawning and terminating the
      -- command which is consistent with the behavior above (with string cmds)
      -- TODO: why does {FZF|SKIM}_DEFAULT_COMMAND cause delay in opening skim?
      -- use input redirection with skim to prevent interface opening delay
      local bin_is_sk = opts.fzf_bin and opts.fzf_bin:match("sk$")
      local fish_shell = vim.o.shell and vim.o.shell:match("fish$")
      if not fish_shell or bin_is_sk then
        table.insert(cmd, "<")
        table.insert(cmd, libuv.shellescape(fifotmpname))
      else
        FZF_DEFAULT_COMMAND = string.format("cat %s", libuv.shellescape(fifotmpname))
      end
    end
  end

  table.insert(cmd, ">")
  table.insert(cmd, libuv.shellescape(outputtmpname))

  local fd, output_pipe = nil, nil
  local finish_called = false
  local write_cb_count = 0
  local windows_pipe_server = nil
  ---@type function|nil
  local handle_contents

  if utils.__IS_WINDOWS then
    windows_pipe_server = uv.new_pipe(false)
    windows_pipe_server:bind(fifotmpname)
    windows_pipe_server:listen(16, function()
      output_pipe = uv.new_pipe(false)
      windows_pipe_server:accept(output_pipe)
      handle_contents()
    end)
  else
    -- Create the output pipe
    -- We use tbl for perf reasons, from ':help system':
    --  If {cmd} is a List it runs directly (no 'shell')
    --  If {cmd} is a String it runs in the 'shell'
    vim.fn.system({ "mkfifo", fifotmpname })
  end

  local function finish(_)
    -- mark finish once called
    finish_called = true
    -- close pipe if there are no outstanding writes
    if output_pipe and write_cb_count == 0 then
      output_pipe:close()
      output_pipe = nil
    end
  end

  local function write_cb(data, cb)
    if not output_pipe then return end
    write_cb_count = write_cb_count + 1
    output_pipe:write(data, function(err)
      -- decrement write call count
      write_cb_count = write_cb_count - 1
      -- this will call the user's cb
      if cb then cb(err) end
      if err then
        -- can fail with premature process kill
        finish(2)
      elseif finish_called and write_cb_count == 0 then
        -- 'termopen.on_exit' already called and did not close the
        -- pipe due to write_cb_count>0, since this is the last call
        -- we can close the fzf pipe
        finish(3)
      end
    end)
  end

  -- nvim-fzf compatibility, builds the user callback functions
  -- 1st argument: callback function that adds newline to each write
  -- 2nd argument: callback function that writes the data as is
  -- 3rd argument: direct access to the pipe object
  local function usr_write_cb(nl)
    local function end_of_data(usrdata, cb)
      if usrdata == nil then
        if cb then cb(nil) end
        finish(5)
        return true
      end
      return false
    end

    if nl then
      return function(usrdata, cb)
        if not end_of_data(usrdata, cb) then
          write_cb(tostring(usrdata) .. "\n", cb)
        end
      end
    else
      return function(usrdata, cb)
        if not end_of_data(usrdata, cb) then
          write_cb(usrdata, cb)
        end
      end
    end
  end

  handle_contents = vim.schedule_wrap(function()
    -- this part runs in the background. When the user has selected, it will
    -- error out, but that doesn't matter so we just break out of the loop.
    if contents then
      if type(contents) == "table" then
        if not vim.tbl_isempty(contents) then
          write_cb(vim.tbl_map(function(x)
            return x .. "\n"
          end, contents))
        end
        finish(4)
      else
        contents(usr_write_cb(true), usr_write_cb(false), output_pipe)
      end
    end
  end)

  if opts.debug then
    print("[Fzf-lua]: FZF_DEFAULT_COMMAND:", FZF_DEFAULT_COMMAND)
    print("[Fzf-lua]: fzf cmd:", table.concat(cmd, " "))
  end

  local pid, chan_id, ns_id, sigint_recieved, fh_trace
  if opts.debug_tracelog then
    fh_trace = io.open(vim.fn.expand(opts.debug_tracelog), "wb")
    if fh_trace then
      debug.sethook(function(_, _)
        local s = string.format("%s %s:%s %s\n",
          os.date("%Y-%m-%dT%H:%M:%S"),
          debug.getinfo(2, "S").source,
          debug.getinfo(2, "l").currentline,
          debug.getinfo(2, "n").name)
        fh_trace:write(s)
        fh_trace:flush()
      end, "l")
    end
  end

  if opts.nvim_freeze_workaround and vim.on_key then
    opts.nvim_freeze_workaround = tonumber(opts.nvim_freeze_workaround) or 2
    ns_id = vim.api.nvim_create_namespace("fzf-lua")
    if tonumber(ns_id) then
      vim.on_key(function(key)
        -- ctrl-c is 0x3
        if string.byte(key, 1) == 3 then
          if not sigint_recieved then
            sigint_recieved = 1
            if opts.nvim_freeze_workaround >= 2 then
              utils.info(string.format("ctrl-c recieved for job %d [pid:%d]...", chan_id, pid))
            end
          else
            sigint_recieved = sigint_recieved + 1
            if type(uv.os_getpriority(pid)) == "number" then
              if opts.nvim_freeze_workaround >= 1 then
                utils.warn(string.format(
                  "%s: ctrl-c seen %d times, terminating job %d [pid:%d]...",
                  os.date(), sigint_recieved, chan_id, pid))
              end
              vim.fn.jobstop(chan_id)
              libuv.process_kill(pid)
            else
              if sigint_recieved > 3 then
                -- process is not alive but we're still in the loop?
                error(string.format("%s, ctr-c seen %d times, pid %d is already dead.",
                  os.date(), sigint_recieved, pid))
              end
            end
          end
        end
        return ns_id
      end, ns_id)
    end
  end

  local function unset_debughook()
    if fh_trace then
      debug.sethook(nil, "", 0)
      fh_trace:close()
    end
  end

  local function unhook_onkey()
    if tonumber(ns_id) and vim.on_key then
      ---@diagnostic disable-next-line: param-type-mismatch
      vim.on_key(nil, ns_id)
    end
  end

  local co = coroutine.running()
  local jobstart = opts.is_fzf_tmux and vim.fn.jobstart or vim.fn.termopen
  local shell_cmd = utils.__IS_WINDOWS
      and { "cmd", "/d", "/e:off", "/f:off", "/v:off", "/c" }
      or { "sh", "-c" }
  if utils.__IS_WINDOWS then
    utils.tbl_extend(shell_cmd, cmd)
  else
    table.insert(shell_cmd, table.concat(cmd, " "))
  end
  -- This obscure option makes jobstart fail with: "The syntax of the command is incorrect"
  -- temporarily set to `false`, for more info see `:help shellslash` (#1055)
  local nvim_opt_shellslash = utils.__WIN_HAS_SHELLSLASH and vim.o.shellslash
  if nvim_opt_shellslash then vim.o.shellslash = false end
  chan_id = jobstart(shell_cmd, {
    cwd = cwd,
    pty = true,
    env = {
      ["SHELL"] = shell_cmd[1],
      ["FZF_DEFAULT_COMMAND"] = FZF_DEFAULT_COMMAND,
      ["SKIM_DEFAULT_COMMAND"] = FZF_DEFAULT_COMMAND,
    },
    on_exit = function(_, rc, _)
      -- clear hook
      unhook_onkey()
      unset_debughook()
      local output = {}
      local f = io.open(outputtmpname)
      if f then
        for v in f:lines() do
          table.insert(output, v)
        end
        f:close()
      end
      finish(1)
      if windows_pipe_server then
        windows_pipe_server:close()
      end
      -- in windows, pipes that are not used are automatically cleaned up
      if not utils.__IS_WINDOWS then vim.fn.delete(fifotmpname) end
      -- Windows only, restore `shellslash` if was true before `jobstart`
      if nvim_opt_shellslash then vim.o.shellslash = nvim_opt_shellslash end
      vim.fn.delete(outputtmpname)
      if #output == 0 then output = nil end
      coroutine.resume(co, output, rc)
    end
  })

  -- job failed or cmd[0] is not executable
  if tonumber(chan_id) < 1 then
    unhook_onkey()
    unset_debughook()
  else
    pid = vim.fn.jobpid(chan_id)
  end

  -- fzf-tmux spawns outside neovim, don't set filetype/insert mode
  if not opts.is_fzf_tmux then
    vim.cmd [[set ft=fzf]]

    -- https://github.com/neovim/neovim/pull/15878
    -- Since patch-8.2.3461 which was released with 0.6 neovim distinguishes between
    -- Normal mode and Terminal-Normal mode. However, this seems to have also introduced
    -- a bug with `startinsert`: When fzf-lua reuses interfaces (e.g. called from "builtin"
    -- or grep<->live_grep toggle) the current mode will be "t" which is Terminal (INSERT)
    -- mode but our interface is still opened in NORMAL mode, either `startinsert` is not
    -- working (as it's technically already in INSERT) or creating a new terminal buffer
    -- within the same window starts in NORMAL mode while returning the wrong `nvim_get_mode`
    if utils.__HAS_NVIM_06 and vim.api.nvim_get_mode().mode == "t" then
      utils.feed_keys_termcodes("i")
    else
      vim.cmd [[startinsert]]
    end
  end

  if not contents or type(contents) == "string" then
    goto wait_for_fzf
  end

  if not utils.__IS_WINDOWS then
    -- have to open this after there is a reader (termopen)
    -- otherwise this will block
    fd = uv.fs_open(fifotmpname, "w", -1)
    output_pipe = uv.new_pipe(false)
    output_pipe:open(fd)
    -- print(output_pipe:getpeername())
    handle_contents()
  end


  ::wait_for_fzf::
  return coroutine.yield()
end

return M
