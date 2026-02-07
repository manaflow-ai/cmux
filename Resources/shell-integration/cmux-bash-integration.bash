# cmuxterm shell integration for bash

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
        # after it has finished writing. cmuxterm keeps the connection open, so
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
_CMUX_PORTS_JOB_PID="${_CMUX_PORTS_JOB_PID:-}"

_cmux_prompt_command() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local now=$SECONDS
    local pwd="$PWD"
    local tty_name=""
    tty_name="$(tty 2>/dev/null || true)"
    tty_name="${tty_name##*/}"
    if [[ "$tty_name" == "not a tty" ]]; then
        tty_name=""
    fi

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
    local should_git=1

    if (( should_git )); then
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
                    _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID"
                else
                    _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID"
                fi
            } >/dev/null 2>&1 &
            _CMUX_GIT_JOB_PID=$!
        fi
    fi

    if (( now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        if [[ -n "$_CMUX_PORTS_JOB_PID" ]] && kill -0 "$_CMUX_PORTS_JOB_PID" 2>/dev/null; then
            : # previous scan still running
        else
            _CMUX_PORTS_LAST_RUN=$now
            {
                local ports=()
                local pids_csv=""
                if [[ -n "$tty_name" ]]; then
                    pids_csv="$(ps -axo pid=,tty= 2>/dev/null | awk -v tty="$tty_name" '$2 == tty {print $1}' | tr '\n' ',' || true)"
                    pids_csv="${pids_csv%,}"
                fi

                if [[ -n "$pids_csv" ]]; then
                    local line name port
                    while IFS= read -r line; do
                        [[ "$line" == n* ]] || continue
                        name="${line#n}"
                        name="${name%%->*}"
                        port="${name##*:}"
                        port="${port%%[^0-9]*}"
                        [[ -n "$port" ]] && ports+=("$port")
                    done < <(
                        lsof -nP -a -p "$pids_csv" -iTCP -sTCP:LISTEN -F n 2>/dev/null || true
                    )
                fi

                if ((${#ports[@]} > 0)); then
                    local ports_sorted
                    ports_sorted=$(printf '%s\n' "${ports[@]}" | sort -n | uniq | tr '\n' ' ')
                    ports_sorted="${ports_sorted%% }"
                    _cmux_send "report_ports $ports_sorted --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                else
                    _cmux_send "clear_ports --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                fi
            } >/dev/null 2>&1 &
            _CMUX_PORTS_JOB_PID=$!
        fi
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

_cmux_install_prompt_command
