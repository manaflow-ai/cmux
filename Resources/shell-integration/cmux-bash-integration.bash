# cmux shell integration for bash

_cmux_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -U "$CMUX_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat - "UNIX-CONNECT:$CMUX_SOCKET_PATH"
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

# Throttle heavy work to avoid prompt latency.
_CMUX_PWD_LAST_PWD="${_CMUX_PWD_LAST_PWD:-}"
_CMUX_GIT_LAST_PWD="${_CMUX_GIT_LAST_PWD:-}"
_CMUX_GIT_LAST_RUN="${_CMUX_GIT_LAST_RUN:-0}"
_CMUX_GIT_JOB_PID="${_CMUX_GIT_JOB_PID:-}"

_CMUX_PORTS_LAST_RUN="${_CMUX_PORTS_LAST_RUN:-0}"
_CMUX_TTY_NAME="${_CMUX_TTY_NAME:-}"
_CMUX_TTY_REPORTED="${_CMUX_TTY_REPORTED:-0}"

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
    } >/dev/null 2>&1 &
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
    } >/dev/null 2>&1 &
}

_cmux_prompt_command() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local now=$SECONDS
    local pwd="$PWD"

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
        } >/dev/null 2>&1 &
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        :
    else
        _CMUX_GIT_LAST_PWD="$pwd"
        _CMUX_GIT_LAST_RUN=$now
        {
            local branch dirty_opt=""
            branch=$(git branch --show-current 2>/dev/null)
            if [[ -n "$branch" ]]; then
                local first
                first=$(git status --porcelain -uno 2>/dev/null | head -1)
                [[ -n "$first" ]] && dirty_opt="--status=dirty"
                local qbranch="${branch//\"/\\\"}"
                _cmux_send "report_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID $dirty_opt -- \"${qbranch}\""
            else
                _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
            fi
        } >/dev/null 2>&1 &
        _CMUX_GIT_JOB_PID=$!
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
}

# Ensure Resources/bin is at the front of PATH. Shell init (.bashrc/.bash_profile)
# may prepend other dirs that push our wrapper behind the system claude binary.
_cmux_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local bin_dir="${GHOSTTY_BIN_DIR%/MacOS}"
        bin_dir="${bin_dir}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local new_path=":${PATH}:"
            new_path="${new_path//:${bin_dir}:/:}"
            new_path="${new_path#:}"
            new_path="${new_path%:}"
            PATH="${bin_dir}:${new_path}"
        fi
    fi
}
_cmux_fix_path
unset -f _cmux_fix_path

_cmux_install_prompt_command
