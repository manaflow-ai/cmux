# cmux shell integration for bash

_cmux_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. cmux keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if printf '%s\n' "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

_cmux_restore_scrollback_once() {
    local path="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset CMUX_RESTORE_SCROLLBACK_FILE

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi
}
_cmux_restore_scrollback_once

# Throttle heavy work to avoid prompt latency.
_CMUX_PWD_LAST_PWD="${_CMUX_PWD_LAST_PWD:-}"
_CMUX_GIT_LAST_PWD="${_CMUX_GIT_LAST_PWD:-}"
_CMUX_GIT_LAST_RUN="${_CMUX_GIT_LAST_RUN:-0}"
_CMUX_GIT_JOB_PID="${_CMUX_GIT_JOB_PID:-}"
_CMUX_GIT_JOB_STARTED_AT="${_CMUX_GIT_JOB_STARTED_AT:-0}"
_CMUX_GIT_HEAD_LAST_PWD="${_CMUX_GIT_HEAD_LAST_PWD:-}"
_CMUX_GIT_HEAD_PATH="${_CMUX_GIT_HEAD_PATH:-}"
_CMUX_GIT_HEAD_SIGNATURE="${_CMUX_GIT_HEAD_SIGNATURE:-}"
_CMUX_PR_POLL_PID="${_CMUX_PR_POLL_PID:-}"
_CMUX_PR_POLL_PWD="${_CMUX_PR_POLL_PWD:-}"
_CMUX_PR_POLL_INTERVAL="${_CMUX_PR_POLL_INTERVAL:-45}"
_CMUX_PR_FORCE="${_CMUX_PR_FORCE:-0}"
_CMUX_ASYNC_JOB_TIMEOUT="${_CMUX_ASYNC_JOB_TIMEOUT:-20}"

_CMUX_PORTS_LAST_RUN="${_CMUX_PORTS_LAST_RUN:-0}"
_CMUX_SHELL_ACTIVITY_LAST="${_CMUX_SHELL_ACTIVITY_LAST:-}"
_CMUX_TTY_NAME="${_CMUX_TTY_NAME:-}"
_CMUX_TTY_REPORTED="${_CMUX_TTY_REPORTED:-0}"

_cmux_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="$PWD"
    while :; do
        if [[ -d "$dir/.git" ]]; then
            printf '%s\n' "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            IFS= read -r line < "$dir/.git" || line=""
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                printf '%s\n' "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

_cmux_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line
    IFS= read -r line < "$head_path" || return 1
    printf '%s\n' "$line"
}

_cmux_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _CMUX_TTY_REPORTED )) && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    [[ -n "$_CMUX_TTY_NAME" ]] || return 0
    _CMUX_TTY_REPORTED=1
    {
        _cmux_send "report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    } >/dev/null 2>&1 & disown
}

_cmux_report_shell_activity_state() {
    local state="$1"
    [[ -n "$state" ]] || return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    [[ "$_CMUX_SHELL_ACTIVITY_LAST" == "$state" ]] && return 0
    _CMUX_SHELL_ACTIVITY_LAST="$state"
    {
        _cmux_send "report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    } >/dev/null 2>&1 & disown
}

_cmux_ports_kick() {
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _CMUX_PORTS_LAST_RUN=$SECONDS
    {
        _cmux_send "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    } >/dev/null 2>&1 & disown
}

_cmux_clear_pr_for_panel() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
}

_cmux_pr_output_indicates_no_pull_request() {
    local output="$1"
    output="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    [[ "$output" == *"no pull requests found"* \
        || "$output" == *"no pull request found"* \
        || "$output" == *"no pull requests associated"* \
        || "$output" == *"no pull request associated"* ]]
}

_cmux_github_repo_slug_for_path() {
    local repo_path="$1"
    local remote_url="" path_part=""
    [[ -n "$repo_path" ]] || return 0

    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)"
    [[ -n "$remote_url" ]] || return 0

    case "$remote_url" in
        git@github.com:*)
            path_part="${remote_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            path_part="${remote_url#ssh://git@github.com/}"
            ;;
        https://github.com/*)
            path_part="${remote_url#https://github.com/}"
            ;;
        http://github.com/*)
            path_part="${remote_url#http://github.com/}"
            ;;
        git://github.com/*)
            path_part="${remote_url#git://github.com/}"
            ;;
        *)
            return 0
            ;;
    esac

    path_part="${path_part%.git}"
    [[ "$path_part" == */* ]] || return 0
    printf '%s\n' "$path_part"
}

_cmux_report_pr_for_path() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || {
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -d "$repo_path" ]] || {
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local branch repo_slug="" gh_output="" gh_error="" err_file="" gh_status number state url status_opt=""
    local -a gh_repo_args=()
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    if [[ -z "$branch" ]] || ! command -v gh >/dev/null 2>&1; then
        _cmux_clear_pr_for_panel
        return 0
    fi
    repo_slug="$(_cmux_github_repo_slug_for_path "$repo_path")"
    if [[ -n "$repo_slug" ]]; then
        gh_repo_args=(--repo "$repo_slug")
    fi

    err_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-gh-pr-view.XXXXXX" 2>/dev/null || true)"
    [[ -n "$err_file" ]] || return 1
    gh_output="$(
        builtin cd "$repo_path" 2>/dev/null \
            && gh pr view "$branch" \
                "${gh_repo_args[@]}" \
                --json number,state,url \
                --jq '[.number, .state, .url] | @tsv' \
                2>"$err_file"
    )"
    gh_status=$?
    if [[ -f "$err_file" ]]; then
        gh_error="$("/bin/cat" -- "$err_file" 2>/dev/null || true)"
        /bin/rm -f -- "$err_file" >/dev/null 2>&1 || true
    fi

    if (( gh_status != 0 )) || [[ -z "$gh_output" ]]; then
        if (( gh_status == 0 )) && [[ -z "$gh_output" ]]; then
            _cmux_clear_pr_for_panel
            return 0
        fi
        if _cmux_pr_output_indicates_no_pull_request "$gh_error"; then
            _cmux_clear_pr_for_panel
            return 0
        fi

        # Always scope PR detection to the exact current branch. Preserve the
        # last-known PR badge when gh fails transiently, then retry on the next
        # background poll instead of showing a mismatched PR.
        return 1
    fi

    IFS=$'\t' read -r number state url <<< "$gh_output"
    if [[ -z "$number" || -z "$url" ]]; then
        return 1
    fi

    case "$state" in
        MERGED) status_opt="--state=merged" ;;
        OPEN) status_opt="--state=open" ;;
        CLOSED) status_opt="--state=closed" ;;
        *) return 1 ;;
    esac

    local quoted_branch="${branch//\"/\\\"}"
    _cmux_send "report_pr $number $url $status_opt --branch=\"$quoted_branch\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
}

_cmux_child_pids() {
    local parent_pid="$1"
    [[ -n "$parent_pid" ]] || return 0
    /bin/ps -ax -o pid= -o ppid= 2>/dev/null | /usr/bin/awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

_cmux_kill_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child_pid=""
    [[ -n "$pid" ]] || return 0

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        [[ "$child_pid" == "$pid" ]] && continue
        _cmux_kill_process_tree "$child_pid" "$signal"
    done < <(_cmux_child_pids "$pid")

    kill "-$signal" "$pid" >/dev/null 2>&1 || true
}

_cmux_run_pr_probe_with_timeout() {
    local repo_path="$1"
    local probe_pid=""
    local started_at=$SECONDS
    local now=$started_at

    (
        _cmux_report_pr_for_path "$repo_path"
    ) &
    probe_pid=$!

    while kill -0 "$probe_pid" >/dev/null 2>&1; do
        sleep 1
        now=$SECONDS
        if (( _CMUX_ASYNC_JOB_TIMEOUT > 0 )) && (( now - started_at >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _cmux_kill_process_tree "$probe_pid" TERM
            sleep 0.2
            if kill -0 "$probe_pid" >/dev/null 2>&1; then
                _cmux_kill_process_tree "$probe_pid" KILL
                sleep 0.2
            fi
            if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
                wait "$probe_pid" >/dev/null 2>&1 || true
            fi
            return 1
        fi
    done

    wait "$probe_pid"
}

_cmux_stop_pr_poll_loop() {
    if [[ -n "$_CMUX_PR_POLL_PID" ]]; then
        # Use SIGKILL directly to avoid blocking sleep in preexec.
        # The poll loop is lightweight and safe to kill abruptly.
        _cmux_kill_process_tree "$_CMUX_PR_POLL_PID" KILL
        _CMUX_PR_POLL_PID=""
    fi
}

_cmux_start_pr_poll_loop() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local watch_pwd="${1:-$PWD}"
    local force_restart="${2:-0}"
    local watch_shell_pid="$$"
    local interval="${_CMUX_PR_POLL_INTERVAL:-45}"

    if [[ "$force_restart" != "1" && "$watch_pwd" == "$_CMUX_PR_POLL_PWD" && -n "$_CMUX_PR_POLL_PID" ]] \
        && kill -0 "$_CMUX_PR_POLL_PID" 2>/dev/null; then
        return 0
    fi

    _cmux_stop_pr_poll_loop
    _CMUX_PR_POLL_PWD="$watch_pwd"

    {
        while :; do
            kill -0 "$watch_shell_pid" 2>/dev/null || break
            _cmux_run_pr_probe_with_timeout "$watch_pwd" || true
            sleep "$interval"
        done
    } >/dev/null 2>&1 &
    _CMUX_PR_POLL_PID=$!
    disown "$_CMUX_PR_POLL_PID" 2>/dev/null || disown
}

_cmux_bash_cleanup() {
    _cmux_stop_pr_poll_loop
}

_cmux_preexec_command() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_shell_activity_state running
    _cmux_report_tty_once
    _cmux_ports_kick
    _cmux_stop_pr_poll_loop
}

_cmux_bash_preexec_hook() {
    _cmux_preexec_command
}

_cmux_prompt_command() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _cmux_report_shell_activity_state prompt

    local now=$SECONDS
    local pwd="$PWD"

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_CMUX_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        elif (( _CMUX_GIT_JOB_STARTED_AT > 0 )) && (( now - _CMUX_GIT_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    # Resolve TTY name once.
    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        {
            local qpwd="${pwd//\"/\\\"}"
            _cmux_send "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        } >/dev/null 2>&1 & disown
    fi

    # Branch can change via aliases/tools while an older probe is still in flight.
    # Track .git/HEAD content so we can restart stale probes immediately.
    local git_head_changed=0
    if [[ "$pwd" != "$_CMUX_GIT_HEAD_LAST_PWD" ]]; then
        _CMUX_GIT_HEAD_LAST_PWD="$pwd"
        _CMUX_GIT_HEAD_PATH="$(_cmux_git_resolve_head_path 2>/dev/null || true)"
        _CMUX_GIT_HEAD_SIGNATURE=""
    fi
    if [[ -n "$_CMUX_GIT_HEAD_PATH" ]]; then
        local head_signature
        head_signature="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH" 2>/dev/null || true)"
        if [[ -n "$head_signature" ]]; then
            if [[ -z "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                # The first observed HEAD value is just the session baseline.
                # Treating it as a branch change clears restore-seeded PR badges
                # before the first background probe can confirm the current PR.
                _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
            elif [[ "$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                git_head_changed=1
                # Also invalidate the PR poller so it refreshes with the new branch.
                _CMUX_PR_FORCE=1
            fi
        fi
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" || "$git_head_changed" == "1" ]]; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ -z "$_CMUX_GIT_JOB_PID" ]] || ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        _CMUX_GIT_LAST_PWD="$pwd"
        _CMUX_GIT_LAST_RUN=$now
        {
            local branch dirty_opt=""
            branch=$(git branch --show-current 2>/dev/null)
            if [[ -n "$branch" ]]; then
                local first
                first=$(git status --porcelain -uno 2>/dev/null | head -1)
                [[ -n "$first" ]] && dirty_opt="--status=dirty"
                _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
            else
                _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
            fi
        } >/dev/null 2>&1 &
        _CMUX_GIT_JOB_PID=$!
        disown
        _CMUX_GIT_JOB_STARTED_AT=$now
    fi

    # Pull request metadata is remote state. Keep polling while the shell sits
    # at a prompt so newly created or merged PRs appear without another command.
    local should_restart_pr_poll=0
    local pr_context_changed=0
    if [[ -n "$_CMUX_PR_POLL_PWD" && "$pwd" != "$_CMUX_PR_POLL_PWD" ]]; then
        pr_context_changed=1
    elif [[ "$git_head_changed" == "1" ]]; then
        pr_context_changed=1
    fi
    if [[ "$pwd" != "$_CMUX_PR_POLL_PWD" || "$git_head_changed" == "1" ]]; then
        should_restart_pr_poll=1
    elif (( _CMUX_PR_FORCE )); then
        should_restart_pr_poll=1
    elif [[ -z "$_CMUX_PR_POLL_PID" ]] || ! kill -0 "$_CMUX_PR_POLL_PID" 2>/dev/null; then
        should_restart_pr_poll=1
    fi

    if (( should_restart_pr_poll )); then
        _CMUX_PR_FORCE=0
        if (( pr_context_changed )); then
            _cmux_clear_pr_for_panel
        fi
        _cmux_start_pr_poll_loop "$pwd" 1
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick
    fi
}

_cmux_install_prompt_command() {
    [[ -n "${_CMUX_PROMPT_INSTALLED:-}" ]] && return 0
    _CMUX_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_cmux_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_cmux_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_cmux_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_cmux_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_cmux_prompt_command"
                fi
                ;;
        esac
    fi

    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
            builtin readonly _CMUX_BASH_PS0='${ _cmux_bash_preexec_hook; }'
        else
            builtin readonly _CMUX_BASH_PS0='$(_cmux_bash_preexec_hook >/dev/null)'
        fi
        if [[ "$PS0" != *"${_CMUX_BASH_PS0}"* ]]; then
            PS0=$PS0"${_CMUX_BASH_PS0}"
        fi
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.bashrc/.bash_profile) may prepend other dirs after launch.
_cmux_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local new_path=":${PATH}:"
            new_path="${new_path//:${bin_dir}:/:}"
            new_path="${new_path//:${gui_dir}:/:}"
            new_path="${new_path#:}"
            new_path="${new_path%:}"
            PATH="${bin_dir}:${new_path}"
        fi
    fi
}
_cmux_fix_path
unset -f _cmux_fix_path

_cmux_install_prompt_command
