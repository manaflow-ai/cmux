# cmux shell integration for fish
# Injected automatically — do not source manually

# Guard: only activate when cmux has injected the required environment variables.
if not set -q CMUX_SHELL_INTEGRATION; or not set -q CMUX_SOCKET_PATH
    # Return so we don't exit the shell (this file is sourced, not executed).
    return 0
end

# ---------------------------------------------------------------------------
# _cmux_send — write a single-line payload to the cmux socket.
# Uses ncat > socat > nc fallback chain.
# ---------------------------------------------------------------------------
function _cmux_send --description "Send a payload to the cmux socket"
    set -l payload $argv[1]
    if command -v ncat >/dev/null 2>&1
        printf '%s\n' $payload | ncat -w 1 -U $CMUX_SOCKET_PATH --send-only
    else if command -v socat >/dev/null 2>&1
        printf '%s\n' $payload | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH"
    else if command -v nc >/dev/null 2>&1
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. cmux keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if printf '%s\n' $payload | nc -N -U $CMUX_SOCKET_PATH >/dev/null 2>&1
            true
        else
            printf '%s\n' $payload | nc -w 1 -U $CMUX_SOCKET_PATH >/dev/null 2>&1; or true
        end
    end
end

# ---------------------------------------------------------------------------
# Scrollback restore — run once at source time.
# If $CMUX_RESTORE_SCROLLBACK_FILE is set and readable, cat and remove it.
# ---------------------------------------------------------------------------
if set -q CMUX_RESTORE_SCROLLBACK_FILE
    set -l _cmux_restore_path $CMUX_RESTORE_SCROLLBACK_FILE
    set -e CMUX_RESTORE_SCROLLBACK_FILE
    if test -r $_cmux_restore_path
        /bin/cat -- $_cmux_restore_path 2>/dev/null; or true
        /bin/rm -f -- $_cmux_restore_path >/dev/null 2>&1; or true
    end
end

# ---------------------------------------------------------------------------
# Global state variables
# ---------------------------------------------------------------------------
set -g _CMUX_PWD_LAST_PWD ""
set -g _CMUX_GIT_LAST_PWD ""
set -g _CMUX_GIT_LAST_RUN 0
set -g _CMUX_GIT_JOB_PID ""
set -g _CMUX_GIT_JOB_STARTED_AT 0
set -g _CMUX_GIT_HEAD_LAST_PWD ""
set -g _CMUX_GIT_HEAD_PATH ""
set -g _CMUX_GIT_HEAD_SIGNATURE ""
set -g _CMUX_GIT_FORCE 0
set -g _CMUX_PR_POLL_PID ""
set -g _CMUX_PR_POLL_PWD ""
set -g _CMUX_PR_POLL_INTERVAL 45
set -g _CMUX_PR_FORCE 0
set -g _CMUX_ASYNC_JOB_TIMEOUT 20
set -g _CMUX_PORTS_LAST_RUN 0
set -g _CMUX_SHELL_ACTIVITY_LAST ""
set -g _CMUX_TTY_NAME ""
set -g _CMUX_TTY_REPORTED 0

# ---------------------------------------------------------------------------
# _cmux_git_resolve_head_path — find .git/HEAD without invoking git.
# Handles worktrees via `gitdir:` in a .git file.
# Prints the resolved path and returns 0 on success, 1 if not in a git repo.
# ---------------------------------------------------------------------------
function _cmux_git_resolve_head_path --description "Find .git/HEAD path including worktrees"
    set -l dir $PWD
    while true
        if test -d $dir/.git
            printf '%s\n' $dir/.git/HEAD
            return 0
        end
        if test -f $dir/.git
            set -l line ""
            read -l line < $dir/.git
            if string match -q 'gitdir:*' -- $line
                set -l gitdir (string replace -r '^gitdir:\s*' '' -- $line)
                set gitdir (string trim -- $gitdir)
                if test -z "$gitdir"
                    return 1
                end
                if not string match -q '/*' -- $gitdir
                    set gitdir $dir/$gitdir
                end
                printf '%s\n' $gitdir/HEAD
                return 0
            end
        end
        if test $dir = / -o -z "$dir"
            break
        end
        set dir (dirname $dir)
    end
    return 1
end

# ---------------------------------------------------------------------------
# _cmux_git_head_signature — read the first line of a HEAD file as a signature.
# ---------------------------------------------------------------------------
function _cmux_git_head_signature --description "Read first line of HEAD file as signature"
    set -l head_path $argv[1]
    if test -z "$head_path"; or not test -r $head_path
        return 1
    end
    set -l line ""
    read -l line < $head_path
    if test $status -ne 0
        return 1
    end
    printf '%s\n' $line
end

# ---------------------------------------------------------------------------
# _cmux_report_tty_once — send the TTY name to the app once per session.
# ---------------------------------------------------------------------------
function _cmux_report_tty_once --description "Report TTY name to app once per session"
    test $_CMUX_TTY_REPORTED -eq 1; and return 0
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0
    test -n "$_CMUX_TTY_NAME"; or return 0
    set -g _CMUX_TTY_REPORTED 1
    _cmux_send "report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" >/dev/null 2>&1 &
    disown $last_pid 2>/dev/null
end

# ---------------------------------------------------------------------------
# _cmux_report_shell_activity_state — send prompt/running state, de-duped.
# ---------------------------------------------------------------------------
function _cmux_report_shell_activity_state --description "Send prompt/running state to app"
    set -l state $argv[1]
    test -n "$state"; or return 0
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0
    test "$_CMUX_SHELL_ACTIVITY_LAST" = "$state"; and return 0
    set -g _CMUX_SHELL_ACTIVITY_LAST $state
    _cmux_send "report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" >/dev/null 2>&1 &
    disown $last_pid 2>/dev/null
end

# ---------------------------------------------------------------------------
# _cmux_ports_kick — tell the app to run a batched scan for this panel.
# The app coalesces kicks across all panels and runs a single ps+lsof.
# ---------------------------------------------------------------------------
function _cmux_ports_kick --description "Trigger batched port scan in app"
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0
    set -g _CMUX_PORTS_LAST_RUN (date +%s)
    _cmux_send "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" >/dev/null 2>&1 &
    disown $last_pid 2>/dev/null
end

# ---------------------------------------------------------------------------
# _cmux_clear_pr_for_panel — clear the PR badge for this panel.
# ---------------------------------------------------------------------------
function _cmux_clear_pr_for_panel --description "Clear PR badge for panel"
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0
    _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
end

# ---------------------------------------------------------------------------
# _cmux_pr_output_indicates_no_pull_request — check if gh error means no PR.
# ---------------------------------------------------------------------------
function _cmux_pr_output_indicates_no_pull_request --description "Check if gh error means no PR"
    set -l output (string lower -- $argv[1])
    string match -q '*no pull requests found*' -- $output; and return 0
    string match -q '*no pull request found*' -- $output; and return 0
    string match -q '*no pull requests associated*' -- $output; and return 0
    string match -q '*no pull request associated*' -- $output; and return 0
    return 1
end

# ---------------------------------------------------------------------------
# _cmux_report_pr_for_path — run gh pr view and send the result to cmux.
# ---------------------------------------------------------------------------
function _cmux_report_pr_for_path --description "Run gh pr view and send result to app"
    set -l repo_path $argv[1]
    if test -z "$repo_path"
        _cmux_clear_pr_for_panel
        return 0
    end
    if not test -d $repo_path
        _cmux_clear_pr_for_panel
        return 0
    end
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0

    set -l branch (git -C $repo_path branch --show-current 2>/dev/null)
    if test -z "$branch"; or not command -v gh >/dev/null 2>&1
        _cmux_clear_pr_for_panel
        return 0
    end

    set -l tmpdir $TMPDIR
    if test -z "$tmpdir"
        set tmpdir /tmp
    end
    set -l err_file (/usr/bin/mktemp "$tmpdir/cmux-gh-pr-view.XXXXXX" 2>/dev/null)
    if test -z "$err_file"
        return 1
    end

    set -l gh_output ""
    cd $repo_path 2>/dev/null
    if test $status -ne 0
        _cmux_clear_pr_for_panel
        /bin/rm -f -- $err_file >/dev/null 2>&1; or true
        return 1
    end
    set gh_output (gh pr view \
        --json number,state,url \
        --jq '[.number, .state, .url] | @tsv' \
        2>$err_file)
    set -l gh_status $status

    set -l gh_error ""
    if test -f $err_file
        set gh_error (cat -- $err_file 2>/dev/null; or true)
        /bin/rm -f -- $err_file >/dev/null 2>&1; or true
    end

    if test $gh_status -ne 0
        if _cmux_pr_output_indicates_no_pull_request "$gh_error"
            # Retry with the explicit branch name before clearing — worktree or
            # implicit-resolution failures may succeed when branch is named directly.
            set -l retry_err_file (/usr/bin/mktemp "$tmpdir/cmux-gh-pr-view.XXXXXX" 2>/dev/null)
            if test -n "$retry_err_file"
                set gh_output (gh pr view "$branch" \
                    --json number,state,url \
                    --jq '[.number, .state, .url] | @tsv' \
                    2>$retry_err_file)
                set gh_status $status
                /bin/rm -f -- $retry_err_file >/dev/null 2>&1; or true
            end
            if test $gh_status -ne 0
                _cmux_clear_pr_for_panel
                return 0
            end
        else
            # Preserve the last-known PR badge when gh fails transiently, then retry
            # on the next background poll instead of clearing visible state.
            return 1
        end
    end

    if test -z "$gh_output"
        _cmux_clear_pr_for_panel
        return 0
    end

    set -l parts (string split \t -- $gh_output)
    set -l number $parts[1]
    set -l state $parts[2]
    set -l url $parts[3]

    if test -z "$number" -o -z "$url"
        return 1
    end

    set -l status_opt ""
    switch $state
        case MERGED
            set status_opt "--state=merged"
        case OPEN
            set status_opt "--state=open"
        case CLOSED
            set status_opt "--state=closed"
        case '*'
            return 1
    end

    _cmux_send "report_pr $number $url $status_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
end

# ---------------------------------------------------------------------------
# _cmux_child_pids — list direct child PIDs of a given process.
# ---------------------------------------------------------------------------
function _cmux_child_pids --description "List direct child PIDs of process"
    set -l parent_pid $argv[1]
    test -n "$parent_pid"; or return 0
    /bin/ps -ax -o pid= -o ppid= 2>/dev/null | /usr/bin/awk -v parent=$parent_pid '$2 == parent { print $1 }'
end

# ---------------------------------------------------------------------------
# _cmux_kill_process_tree — recursively kill a process and all its children.
# ---------------------------------------------------------------------------
function _cmux_kill_process_tree --description "Recursively kill process and children"
    set -l pid $argv[1]
    set -l signal TERM
    if test (count $argv) -ge 2
        set signal $argv[2]
    end
    test -n "$pid"; or return 0

    for child_pid in (_cmux_child_pids $pid)
        test -n "$child_pid"; or continue
        test "$child_pid" = "$pid"; and continue
        _cmux_kill_process_tree $child_pid $signal
    end

    kill -$signal $pid >/dev/null 2>&1; or true
end

# ---------------------------------------------------------------------------
# _cmux_stop_pr_poll_loop — kill the background PR poll loop if running.
# ---------------------------------------------------------------------------
function _cmux_stop_pr_poll_loop --description "Kill background PR poll loop"
    if test -n "$_CMUX_PR_POLL_PID"
        # Use SIGKILL directly to avoid blocking sleep in preexec.
        # The poll loop is lightweight and safe to kill abruptly.
        _cmux_kill_process_tree $_CMUX_PR_POLL_PID KILL
        set -g _CMUX_PR_POLL_PID ""
    end
end

# ---------------------------------------------------------------------------
# _cmux_start_pr_poll_loop — start (or restart) the background PR poll loop.
#
# The poll loop runs as a background fish -c process. It sources the
# integration file using the path stored in $_CMUX_INTEGRATION_FILE so that
# _cmux_report_pr_for_path and _cmux_send are available. The integration file
# path is set once below after all functions are defined.
# ---------------------------------------------------------------------------
function _cmux_start_pr_poll_loop --description "Start or restart background PR poll loop"
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0

    set -l watch_pwd $PWD
    if test (count $argv) -ge 1
        set watch_pwd $argv[1]
    end
    set -l force_restart 0
    if test (count $argv) -ge 2
        set force_restart $argv[2]
    end
    set -l watch_shell_pid $fish_pid
    set -l interval $_CMUX_PR_POLL_INTERVAL
    set -l async_timeout $_CMUX_ASYNC_JOB_TIMEOUT
    set -l socket_path $CMUX_SOCKET_PATH
    set -l tab_id $CMUX_TAB_ID
    set -l panel_id $CMUX_PANEL_ID
    set -l integration_file $_CMUX_INTEGRATION_FILE

    if test $force_restart -ne 1
        and test "$watch_pwd" = "$_CMUX_PR_POLL_PWD"
        and test -n "$_CMUX_PR_POLL_PID"
        and kill -0 $_CMUX_PR_POLL_PID 2>/dev/null
        return 0
    end

    _cmux_stop_pr_poll_loop
    set -g _CMUX_PR_POLL_PWD $watch_pwd

    # Escape single quotes in paths interpolated into fish -c strings.
    set -l escaped_pwd (string replace -a "'" "\\'" -- $watch_pwd)
    set -l escaped_socket (string replace -a "'" "\\'" -- $socket_path)
    set -l escaped_integration (string replace -a "'" "\\'" -- $integration_file)

    # Build a self-contained poll loop script that sources the integration
    # file to get access to _cmux_send and _cmux_report_pr_for_path.
    fish -c "
set -x CMUX_SOCKET_PATH '$escaped_socket'
set -x CMUX_TAB_ID '$tab_id'
set -x CMUX_PANEL_ID '$panel_id'
set -x CMUX_SHELL_INTEGRATION 1
source '$escaped_integration'
set -l watch_pwd '$escaped_pwd'
set -l interval $interval
set -l watch_shell_pid $watch_shell_pid
set -l async_timeout $async_timeout
while true
    kill -0 \$watch_shell_pid >/dev/null 2>&1; or break
    # Run probe in a subprocess so we can apply a timeout.
    fish -c \"
set -x CMUX_SOCKET_PATH '$escaped_socket'
set -x CMUX_TAB_ID '$tab_id'
set -x CMUX_PANEL_ID '$panel_id'
set -x CMUX_SHELL_INTEGRATION 1
source '$escaped_integration'
_cmux_report_pr_for_path '$escaped_pwd'
\" >/dev/null 2>&1 &
    set -l probe_pid \$last_pid
    set -l started_at (date +%s)
    set -l timed_out 0
    while kill -0 \$probe_pid >/dev/null 2>&1
        sleep 1
        set -l now (date +%s)
        if test \$async_timeout -gt 0; and test (math \$now - \$started_at) -ge \$async_timeout
            _cmux_kill_process_tree \$probe_pid KILL
            set timed_out 1
            break
        end
    end
    sleep \$interval
end
" >/dev/null 2>&1 &
    set -g _CMUX_PR_POLL_PID $last_pid
    disown $_CMUX_PR_POLL_PID 2>/dev/null
end

# ---------------------------------------------------------------------------
# Preexec hook — called before each command runs.
# ---------------------------------------------------------------------------
function _cmux_fish_preexec --description "Preexec hook before command runs" --on-event fish_preexec
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0

    if test -z "$_CMUX_TTY_NAME"
        set -l tty_raw (tty 2>/dev/null; or true)
        set tty_raw (string replace -r '^.*/' '' -- $tty_raw)
        if test -n "$tty_raw" -a "$tty_raw" != "not a tty"
            set -g _CMUX_TTY_NAME $tty_raw
        end
    end

    _cmux_report_shell_activity_state running

    # Heuristic: commands that may change git branch/dirty state without changing $PWD.
    set -l command_string (string trim -- "$argv[1]")
    switch $command_string
        case 'git *' git 'gh *' lazygit 'lazygit *' tig 'tig *' gitui 'gitui *' 'stg *' 'jj *'
            set -g _CMUX_GIT_FORCE 1
            set -g _CMUX_PR_FORCE 1
    end

    _cmux_report_tty_once
    _cmux_ports_kick
    _cmux_stop_pr_poll_loop
end

# ---------------------------------------------------------------------------
# Prompt (precmd) hook — called before each prompt is drawn.
# ---------------------------------------------------------------------------
function _cmux_fish_prompt --description "Prompt hook before prompt is drawn" --on-event fish_prompt
    test -S $CMUX_SOCKET_PATH; or return 0
    test -n "$CMUX_TAB_ID"; or return 0
    test -n "$CMUX_PANEL_ID"; or return 0

    _cmux_report_shell_activity_state prompt

    set -l now (date +%s)
    set -l pwd $PWD

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if test -n "$_CMUX_GIT_JOB_PID"
        if not kill -0 $_CMUX_GIT_JOB_PID 2>/dev/null
            set -g _CMUX_GIT_JOB_PID ""
            set -g _CMUX_GIT_JOB_STARTED_AT 0
        else if test $_CMUX_GIT_JOB_STARTED_AT -gt 0
            and test (math $now - $_CMUX_GIT_JOB_STARTED_AT) -ge $_CMUX_ASYNC_JOB_TIMEOUT
            _cmux_kill_process_tree $_CMUX_GIT_JOB_PID KILL
            set -g _CMUX_GIT_JOB_PID ""
            set -g _CMUX_GIT_JOB_STARTED_AT 0
        end
    end

    # Resolve TTY name once.
    if test -z "$_CMUX_TTY_NAME"
        set -l tty_raw (tty 2>/dev/null; or true)
        set tty_raw (string replace -r '^.*/' '' -- $tty_raw)
        if test "$tty_raw" != "not a tty"
            set -g _CMUX_TTY_NAME $tty_raw
        end
    end

    _cmux_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if test "$pwd" != "$_CMUX_PWD_LAST_PWD"
        set -g _CMUX_PWD_LAST_PWD $pwd
        set -l quoted_pwd (string replace -a '"' '\\"' -- $pwd)
        _cmux_send "report_pwd \"$quoted_pwd\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" >/dev/null 2>&1 &
        disown $last_pid 2>/dev/null
    end

    # HEAD signature tracking: detect branch/commit changes without running git.
    # Uses the precmd-based approach (like bash) — no background watcher.
    set -l git_head_changed 0
    if test "$pwd" != "$_CMUX_GIT_HEAD_LAST_PWD"
        set -g _CMUX_GIT_HEAD_LAST_PWD $pwd
        set -g _CMUX_GIT_HEAD_PATH (_cmux_git_resolve_head_path 2>/dev/null; or printf '')
        set -g _CMUX_GIT_HEAD_SIGNATURE ""
    end
    if test -n "$_CMUX_GIT_HEAD_PATH"
        set -l head_signature (_cmux_git_head_signature $_CMUX_GIT_HEAD_PATH 2>/dev/null; or printf '')
        if test -n "$head_signature" -a "$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE"
            if test -n "$_CMUX_GIT_HEAD_SIGNATURE"
                # Signature changed from a known baseline — force both probes to refresh.
                set git_head_changed 1
                set -g _CMUX_GIT_FORCE 1
                set -g _CMUX_PR_FORCE 1
            end
            # Always update the stored signature (baseline on first read, track changes after).
            set -g _CMUX_GIT_HEAD_SIGNATURE $head_signature
        end
    end

    # Git branch/dirty: decide whether to launch a new async probe this prompt.
    # Throttle to avoid redundant git calls, but always refresh on directory
    # change, HEAD change, or after a git-related command (_CMUX_GIT_FORCE).
    set -l should_git 0
    if test "$pwd" != "$_CMUX_GIT_LAST_PWD"
        set should_git 1
    else if test $_CMUX_GIT_FORCE -eq 1
        set should_git 1
    else if test (math $now - $_CMUX_GIT_LAST_RUN) -ge 3
        set should_git 1
    end
    # HEAD change always forces a refresh (set above in the HEAD tracking block).
    test $git_head_changed -eq 1; and set should_git 1

    if test $should_git -eq 1
        set -l can_launch_git 1
        if test -n "$_CMUX_GIT_JOB_PID"
            and kill -0 $_CMUX_GIT_JOB_PID 2>/dev/null
            # If a stale probe is still running but the cwd changed or we just ran
            # a git command, restart immediately so branch state isn't delayed.
            if test "$pwd" != "$_CMUX_GIT_LAST_PWD"; or test $_CMUX_GIT_FORCE -eq 1
                _cmux_kill_process_tree $_CMUX_GIT_JOB_PID KILL
                set -g _CMUX_GIT_JOB_PID ""
                set -g _CMUX_GIT_JOB_STARTED_AT 0
            else
                set can_launch_git 0
            end
        end

        if test $can_launch_git -eq 1
            set -g _CMUX_GIT_FORCE 0
            set -g _CMUX_GIT_LAST_PWD $pwd
            set -g _CMUX_GIT_LAST_RUN $now
            # Source the integration file so _cmux_send is available in the subprocess.
            set -l escaped_socket (string replace -a "'" "\\'" -- $CMUX_SOCKET_PATH)
            set -l escaped_integration (string replace -a "'" "\\'" -- $_CMUX_INTEGRATION_FILE)
            set -l tab_id $CMUX_TAB_ID
            set -l panel_id $CMUX_PANEL_ID
            fish -c "
set -x CMUX_SOCKET_PATH '$escaped_socket'
set -x CMUX_TAB_ID '$tab_id'
set -x CMUX_PANEL_ID '$panel_id'
set -x CMUX_SHELL_INTEGRATION 1
source '$escaped_integration'
set -l branch (git branch --show-current 2>/dev/null)
if test -n \"\$branch\"
    set -l first (git status --porcelain -uno 2>/dev/null | head -1)
    set -l dirty_opt ''
    if test -n \"\$first\"; set dirty_opt '--status=dirty'; end
    _cmux_send \"report_git_branch \$branch \$dirty_opt --tab=$tab_id --panel=$panel_id\"
else
    _cmux_send \"clear_git_branch --tab=$tab_id --panel=$panel_id\"
end
" >/dev/null 2>&1 &
            set -g _CMUX_GIT_JOB_PID $last_pid
            disown $_CMUX_GIT_JOB_PID 2>/dev/null
            set -g _CMUX_GIT_JOB_STARTED_AT $now
        end
    end

    # Pull request: restart the poll loop when directory or HEAD changes.
    set -l should_restart_pr_poll 0
    set -l pr_context_changed 0
    if test -n "$_CMUX_PR_POLL_PWD" -a "$pwd" != "$_CMUX_PR_POLL_PWD"
        set pr_context_changed 1
    else if test $git_head_changed -eq 1
        set pr_context_changed 1
    end
    if test "$pwd" != "$_CMUX_PR_POLL_PWD" -o $git_head_changed -eq 1
        set should_restart_pr_poll 1
    else if test $_CMUX_PR_FORCE -eq 1
        set should_restart_pr_poll 1
    else if test -z "$_CMUX_PR_POLL_PID"
        or not kill -0 $_CMUX_PR_POLL_PID 2>/dev/null
        set should_restart_pr_poll 1
    end

    if test $should_restart_pr_poll -eq 1
        set -g _CMUX_PR_FORCE 0
        if test $pr_context_changed -eq 1
            _cmux_clear_pr_for_panel
        end
        _cmux_start_pr_poll_loop $pwd 1
    end

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if test (math $now - $_CMUX_PORTS_LAST_RUN) -ge 10
        _cmux_ports_kick
    end
end

# ---------------------------------------------------------------------------
# PATH fix — run once on first prompt, then self-remove.
# Prepend Resources/bin, remove MacOS dir from PATH.
# Shell init files may prepend other dirs after launch; fix on first prompt
# after all init files have run.
# ---------------------------------------------------------------------------
function _cmux_fix_path --description "Fix PATH on first prompt then remove" --on-event fish_prompt
    if set -q GHOSTTY_BIN_DIR
        set -l gui_dir (string replace -r '/$' '' -- $GHOSTTY_BIN_DIR)
        set -l bin_dir (string replace -r '/MacOS$' '' -- $gui_dir)/Resources/bin
        if test -d $bin_dir
            # Remove existing entries for bin_dir and gui_dir, then prepend bin_dir.
            # In fish, $PATH is already a list — no need to split on ':'.
            set -l new_parts
            for part in $PATH
                if test "$part" != "$bin_dir" -a "$part" != "$gui_dir"
                    set -a new_parts $part
                end
            end
            set -gx PATH $bin_dir $new_parts
        end
    end
    # Self-remove after first run.
    functions -e _cmux_fix_path
end

# ---------------------------------------------------------------------------
# Store the integration file path so the PR poll loop can source it.
# This must come after all function definitions.
# ---------------------------------------------------------------------------
set -g _CMUX_INTEGRATION_FILE (status filename)

# ---------------------------------------------------------------------------
# Cleanup on shell exit.
# ---------------------------------------------------------------------------
function _cmux_fish_exit --description "Cleanup on shell exit" --on-event fish_exit
    if test -n "$_CMUX_GIT_JOB_PID"
        _cmux_kill_process_tree $_CMUX_GIT_JOB_PID KILL
    end
    _cmux_stop_pr_poll_loop
end
