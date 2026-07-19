# cmux shell integration for fish
# Injected automatically, do not source manually.

set -l _cmux_integration_enabled 1
if set -q CMUX_SHELL_INTEGRATION; and test "$CMUX_SHELL_INTEGRATION" = 0
    set _cmux_integration_enabled 0
end

if test "$_cmux_integration_enabled" != 0
    set -g _CMUX_SEND_TOOL ""
    if command -sq ncat
        set -g _CMUX_SEND_TOOL ncat
    else if command -sq socat
        set -g _CMUX_SEND_TOOL socat
    else if command -sq nc
        set -g _CMUX_SEND_TOOL nc
    end

    set -g _CMUX_SHELL_ACTIVITY_LAST ""
    set -g _CMUX_PORTS_LAST_RUN 0
    set -g _CMUX_TTY_NAME ""
    set -g _CMUX_TTY_REPORTED 0
    set -g _CMUX_PWD_LAST_PWD ""
    set -g _CMUX_TMUX_PULL_SIGNATURE ""
    set -g _CMUX_TMUX_PUSH_SIGNATURE ""
    set -g _CMUX_TMUX_SYNC_KEYS \
        CMUX_BUNDLED_CLI_PATH \
        CMUX_BUNDLE_ID \
        CMUXD_UNIX_PATH \
        CMUXTERM_REPO_ROOT \
        CMUX_DEBUG_LOG \
        CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION \
        CMUX_PORT \
        CMUX_PORT_END \
        CMUX_PORT_RANGE \
        CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD \
        CMUX_SHELL_INTEGRATION \
        CMUX_SHELL_INTEGRATION_DIR \
        CMUX_SOCKET_ENABLE \
        CMUX_SOCKET_MODE \
        CMUX_SOCKET_PATH \
        CMUX_TAB_ID \
        CMUX_TAG \
        CMUX_WORKSPACE_ID
    set -g _CMUX_TMUX_SURFACE_SCOPED_KEYS CMUX_PANEL_ID CMUX_SURFACE_ID

    function _cmux_tmux_sync_key_is_managed --argument-names candidate
        contains -- "$candidate" $_CMUX_TMUX_SYNC_KEYS
    end

    function _cmux_tmux_shell_env_signature
        set -l parts
        for key in $_CMUX_TMUX_SYNC_KEYS
            set -q $key; or continue
            test -n "$$key"; or continue
            set -a parts "$key=$$key"
        end
        string join \x1f -- $parts
    end

    function _cmux_tmux_publish_cmux_environment
        if set -q TMUX; and test -n "$TMUX"
            return 0
        end
        command -sq tmux; or functions -q tmux; or return 0

        set -l signature (_cmux_tmux_shell_env_signature)
        test -n "$signature"; or return 0
        test "$signature" = "$_CMUX_TMUX_PUSH_SIGNATURE"; and return 0

        for key in $_CMUX_TMUX_SYNC_KEYS
            set -q $key; or continue
            test -n "$$key"; or continue
            tmux set-environment -g "$key" "$$key" >/dev/null 2>&1; or return 0
        end
        for key in $_CMUX_TMUX_SURFACE_SCOPED_KEYS
            tmux set-environment -gu "$key" >/dev/null 2>&1; or return 0
        end
        set -g _CMUX_TMUX_PUSH_SIGNATURE "$signature"
    end

    function _cmux_tmux_refresh_cmux_environment
        set -q TMUX; and test -n "$TMUX"; or return 0
        command -sq tmux; or functions -q tmux; or return 0

        set -l did_change 0
        for key in $_CMUX_TMUX_SURFACE_SCOPED_KEYS
            if set -q $key
                set -e $key
                set did_change 1
            end
        end

        set -l output (tmux show-environment 2>/dev/null); or return 0
        set -l filtered
        for line in $output
            string match -q 'CMUX_*=*' -- "$line"; or continue
            set -l parts (string split -m 1 '=' -- "$line")
            _cmux_tmux_sync_key_is_managed "$parts[1]"; or continue
            set -a filtered "$line"
        end
        test (count $filtered) -gt 0; or return 0

        set -l signature (string join \x1e -- $filtered)
        if test "$signature" = "$_CMUX_TMUX_PULL_SIGNATURE"; and test "$did_change" = 0
            return 0
        end

        for line in $filtered
            set -l parts (string split -m 1 '=' -- "$line")
            set -l key "$parts[1]"
            set -l value "$parts[2]"
            if not set -q $key; or test "$$key" != "$value"
                set -gx $key "$value"
                set did_change 1
            end
        end

        set -g _CMUX_TMUX_PULL_SIGNATURE "$signature"
        if test "$did_change" = 1
            set -g _CMUX_TTY_REPORTED 0
            set -g _CMUX_SHELL_ACTIVITY_LAST ""
            set -g _CMUX_PWD_LAST_PWD ""
        end
    end

    function _cmux_tmux_sync_cmux_environment
        if set -q TMUX; and test -n "$TMUX"
            _cmux_tmux_refresh_cmux_environment
        else
            _cmux_tmux_publish_cmux_environment
        end
    end

    function _cmux_restore_scrollback_once
        set -l path "$CMUX_RESTORE_SCROLLBACK_FILE"
        test -n "$path"; or return 0
        set -e CMUX_RESTORE_SCROLLBACK_FILE
        set -l token (string replace -r '^.*/' '' -- "$path")
        set -l host (/bin/hostname)

        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/start\007' "$host" "$token"
        if test -r "$path"
            /bin/cat -- "$path" 2>/dev/null; or true
            /bin/rm -f -- "$path" >/dev/null 2>&1; or true
        end
        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/end\007' "$host" "$token"
        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$host" "$PWD"
    end
    _cmux_restore_scrollback_once

    function _cmux_now
        if test -n "$EPOCHSECONDS"
            printf '%s\n' "$EPOCHSECONDS"
        else
            date +%s
        end
    end

    function _cmux_socket_is_unix
        test -n "$CMUX_SOCKET_PATH"; and test -S "$CMUX_SOCKET_PATH"
    end

    function _cmux_relay_cli_path
        if test -n "$CMUX_BUNDLED_CLI_PATH"; and test -x "$CMUX_BUNDLED_CLI_PATH"
            printf '%s\n' "$CMUX_BUNDLED_CLI_PATH"
            return 0
        end
        command -v cmux 2>/dev/null
    end

    function _cmux_socket_uses_remote_relay
        test -n "$CMUX_SOCKET_PATH"; or return 1
        string match -q '/*' -- "$CMUX_SOCKET_PATH"; and return 1
        string match -q '*:*' -- "$CMUX_SOCKET_PATH"; or return 1
        set -l relay_cli (_cmux_relay_cli_path)
        test -n "$relay_cli"
    end

    function _cmux_send --argument-names payload
        test -n "$payload"; or return 0
        test -n "$CMUX_SOCKET_PATH"; or return 0
        switch "$_CMUX_SEND_TOOL"
            case ncat
                printf '%s\n' "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only >/dev/null 2>&1
            case socat
                printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" >/dev/null 2>&1
            case nc
                printf '%s\n' "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; or printf '%s\n' "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1
        end
    end

    function _cmux_send_bg --argument-names payload
        _cmux_send "$payload" >/dev/null 2>&1 &
    end

    function _cmux_json_escape --argument-names value
        set -l backslash "\\"
        set -l escaped_backslash "\\\\"
        set -l quote '"'
        set -l escaped_quote '\"'
        string replace -a "$backslash" "$escaped_backslash" -- "$value" \
            | string replace -a "$quote" "$escaped_quote" \
            | string replace -a (printf '\n') "\\n" \
            | string replace -a (printf '\r') "\\r" \
            | string replace -a (printf '\t') "\\t"
    end

    function _cmux_relay_workspace_id
        if test -n "$CMUX_WORKSPACE_ID"
            printf '%s\n' "$CMUX_WORKSPACE_ID"
            return 0
        end
        test -n "$CMUX_TAB_ID"; or return 1
        printf '%s\n' "$CMUX_TAB_ID"
    end

    function _cmux_relay_rpc_bg --argument-names method params
        _cmux_socket_uses_remote_relay; or return 1
        set -l relay_cli (_cmux_relay_cli_path)
        test -n "$relay_cli"; or return 1
        "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 &
    end

    function _cmux_report_tty_via_relay
        _cmux_socket_uses_remote_relay; or return 1
        test -n "$_CMUX_TTY_NAME"; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        set -l tty_name_json (_cmux_json_escape "$_CMUX_TTY_NAME")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
        if test -n "$CMUX_PANEL_ID"
            set params "$params,\"surface_id\":\"$CMUX_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc_bg surface.report_tty "$params"
    end

    function _cmux_report_pwd_via_relay --argument-names pwd
        _cmux_socket_uses_remote_relay; or return 1
        test -n "$pwd"; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        set -l pwd_json (_cmux_json_escape "$pwd")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"path\":\"$pwd_json\""
        if test -n "$CMUX_PANEL_ID"
            set params "$params,\"surface_id\":\"$CMUX_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc_bg surface.report_pwd "$params"
    end

    function _cmux_report_shell_activity_state_via_relay --argument-names state
        _cmux_socket_uses_remote_relay; or return 1
        test -n "$state"; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        set -l params "{\"workspace_id\":\"$workspace_id\",\"state\":\"$state\""
        if test -n "$CMUX_PANEL_ID"
            set params "$params,\"surface_id\":\"$CMUX_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc_bg surface.report_shell_state "$params"
    end

    function _cmux_ports_kick_via_relay --argument-names reason
        _cmux_socket_uses_remote_relay; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        test -n "$reason"; or set reason command
        set -l params "{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
        if test -n "$CMUX_PANEL_ID"
            set params "$params,\"surface_id\":\"$CMUX_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc_bg surface.ports_kick "$params"
    end

    function _cmux_path_prepend_unique_directory --argument-names directory
        test -n "$directory"; or return 0
        set -l next_path "$directory"
        for entry in $PATH
            test "$entry" = "$directory"; and continue
            set -a next_path "$entry"
        end
        set -gx PATH $next_path
    end

    function _cmux_install_cli_command_shim --argument-names command_name wrapper_path
        set -l tmp_root /tmp
        if set -q TMPDIR; and test -n "$TMPDIR"
            set tmp_root "$TMPDIR"
        end
        set -l surface_component "$fish_pid"
        if set -q CMUX_SURFACE_ID; and test -n "$CMUX_SURFACE_ID"
            set surface_component "$CMUX_SURFACE_ID"
        end
        set -l shim_root "$tmp_root/cmux-cli-shims/$surface_component"
        set -l shim_path "$shim_root/$command_name"
        mkdir -p "$shim_root" >/dev/null 2>&1; or return 0
        begin
            printf '%s\n' '#!/usr/bin/env bash'
            if test "$command_name" = claude
                printf 'cmux_wrapper=%s\n' (string escape --style=script -- "$wrapper_path")
                printf '%s\n' 'if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then'
                printf '%s\n' '    cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-claude-wrapper"'
                printf '%s\n' '    if [[ -x "$cmux_candidate" ]]; then'
                printf '%s\n' '        cmux_wrapper="$cmux_candidate"'
                printf '%s\n' '    fi'
                printf '%s\n' 'fi'
                printf '%s\n' 'if [[ ! -x "$cmux_wrapper" ]]; then'
                printf '%s\n' '    cmux_cli="$(command -v cmux 2>/dev/null || true)"'
                printf '%s\n' '    if [[ -n "$cmux_cli" ]]; then'
                printf '%s\n' '        cmux_candidate="$(dirname "$cmux_cli")/cmux-claude-wrapper"'
                printf '%s\n' '        if [[ -x "$cmux_candidate" ]]; then'
                printf '%s\n' '            cmux_wrapper="$cmux_candidate"'
                printf '%s\n' '        fi'
                printf '%s\n' '    fi'
                printf '%s\n' 'fi'
                printf 'export CMUX_CLAUDE_WRAPPER_SHIM=%s\n' (string escape --style=script -- "$shim_path")
                printf 'export CMUX_CLAUDE_WRAPPER_SHIM_ROOT=%s\n' (string escape --style=script -- "$shim_root")
                printf '%s\n' 'if [[ -x "$cmux_wrapper" ]]; then'
                printf '%s\n' '    exec "$cmux_wrapper" "$@"'
                printf '%s\n' 'fi'
                printf '%s\n' 'cmux_path_without_shim=""'
                printf '%s\n' 'cmux_old_ifs="$IFS"'
                printf '%s\n' 'IFS=:'
                printf '%s\n' 'for cmux_entry in ${PATH:-}; do'
                printf '%s\n' '    if [[ "$cmux_entry" == "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then'
                printf '%s\n' '        continue'
                printf '%s\n' '    fi'
                printf '%s\n' '    if [[ -z "$cmux_path_without_shim" ]]; then'
                printf '%s\n' '        cmux_path_without_shim="$cmux_entry"'
                printf '%s\n' '    else'
                printf '%s\n' '        cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"'
                printf '%s\n' '    fi'
                printf '%s\n' 'done'
                printf '%s\n' 'IFS="$cmux_old_ifs"'
                printf '%s\n' 'export PATH="$cmux_path_without_shim"'
                printf '%s\n' 'exec claude "$@"'
            else
                printf 'exec %s "$@"\n' (string escape --style=script -- "$wrapper_path")
            end
        end >"$shim_path" 2>/dev/null; or return 0
        chmod 0700 "$shim_path" >/dev/null 2>&1; or return 0
        if test "$command_name" = claude
            set -gx CMUX_CLAUDE_WRAPPER_SHIM "$shim_path"
            set -gx CMUX_CLAUDE_WRAPPER_SHIM_ROOT "$shim_root"
        end
        _cmux_path_prepend_unique_directory "$shim_root"
    end

    function _cmux_install_cli_wrapper --argument-names command_name wrapper_file
        test -n "$CMUX_SHELL_INTEGRATION_DIR"; or return 0
        set -l integration_dir (string replace -r '/$' '' -- "$CMUX_SHELL_INTEGRATION_DIR")
        set -l bundle_dir (string replace -r '/shell-integration$' '' -- "$integration_dir")
        set -l wrapper_path "$bundle_dir/bin/$wrapper_file"
        test -x "$wrapper_path"; or return 0

        if test "$command_name" = claude
            _cmux_install_cli_command_shim "$command_name" "$wrapper_path"
        end
        functions -q "$command_name"; and return 0
        switch "$command_name"
            case claude
                function claude --wraps "$wrapper_path" --inherit-variable wrapper_path
                    if test -x "$CMUX_CLAUDE_WRAPPER_SHIM"
                        "$CMUX_CLAUDE_WRAPPER_SHIM" $argv
                    else if test -x "$wrapper_path"
                        "$wrapper_path" $argv
                    else
                        command claude $argv
                    end
                end
            case grok
                function grok --wraps "$wrapper_path" --inherit-variable wrapper_path
                    "$wrapper_path" $argv
                end
        end
    end

    _cmux_install_cli_wrapper claude cmux-claude-wrapper
    _cmux_install_cli_wrapper grok grok

    function _cmux_report_tty_once
        test "$_CMUX_TTY_REPORTED" = 1; and return 0
        if test -z "$_CMUX_TTY_NAME"
            set -g _CMUX_TTY_NAME (tty 2>/dev/null | string replace -r '^.*/' '')
        end
        test -n "$_CMUX_TTY_NAME"; or return 0
        test "$_CMUX_TTY_NAME" != "not a tty"; or return 0

        if _cmux_socket_is_unix
            test -n "$CMUX_TAB_ID"; or return 0
            test -n "$CMUX_PANEL_ID"; or return 0
            set -g _CMUX_TTY_REPORTED 1
            _cmux_send_bg "report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        else if _cmux_socket_uses_remote_relay
            set -g _CMUX_TTY_REPORTED 1
            _cmux_report_tty_via_relay
        end
    end

    function _cmux_report_shell_activity_state --argument-names state
        test -n "$state"; or return 0
        test -n "$CMUX_TAB_ID"; or return 0
        if _cmux_socket_is_unix
            test -n "$CMUX_PANEL_ID"; or return 0
        end
        test "$_CMUX_SHELL_ACTIVITY_LAST" = "$state"; and return 0
        set -g _CMUX_SHELL_ACTIVITY_LAST "$state"
        if _cmux_socket_is_unix
            _cmux_send_bg "report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        else
            _cmux_report_shell_activity_state_via_relay "$state"; or set -g _CMUX_SHELL_ACTIVITY_LAST ""
        end
    end

    function _cmux_reset_terminal_keyboard_protocols
        isatty stdout; or test -n "$CMUX_TEST_FORCE_KEYBOARD_RESET$CMUX_TEST_FORCE_KITTY_RESET"; or return 0
        printf '\033[>m\033[<8u'
    end

    function _cmux_ports_kick --argument-names reason
        test -n "$reason"; or set reason command
        test -n "$CMUX_TAB_ID"; or return 0
        set -g _CMUX_PORTS_LAST_RUN (_cmux_now)
        if _cmux_socket_is_unix
            test -n "$CMUX_PANEL_ID"; or return 0
            _cmux_send_bg "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID --reason=$reason"
        else
            _cmux_ports_kick_via_relay "$reason"
        end
    end

    function _cmux_preexec --on-event fish_preexec
        _cmux_tmux_sync_cmux_environment
        _cmux_report_tty_once
        _cmux_report_shell_activity_state running
        _cmux_ports_kick command
    end

    function _cmux_prompt --on-event fish_prompt
        _cmux_tmux_sync_cmux_environment
        _cmux_reset_terminal_keyboard_protocols
        _cmux_report_tty_once
        _cmux_report_shell_activity_state prompt
        set -l pwd "$PWD"
        if test "$pwd" != "$_CMUX_PWD_LAST_PWD"
            if _cmux_socket_is_unix
                if test -n "$CMUX_TAB_ID"; and test -n "$CMUX_PANEL_ID"
                    set -l qpwd (_cmux_json_escape "$pwd")
                    if _cmux_send_bg "report_pwd \"$qpwd\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                        set -g _CMUX_PWD_LAST_PWD "$pwd"
                    end
                end
            else if _cmux_report_pwd_via_relay "$pwd"
                set -g _CMUX_PWD_LAST_PWD "$pwd"
            end
        end
        set -l now (_cmux_now)
        if test (math "$now - $_CMUX_PORTS_LAST_RUN") -ge 5
            _cmux_ports_kick refresh
        end
    end
end

set -l _cmux_user_config_home ""
if set -q CMUX_FISH_CONFIG_HOME
    set _cmux_user_config_home "$CMUX_FISH_CONFIG_HOME"
else if set -q HOME
    set _cmux_user_config_home "$HOME/.config"
end

set -l _cmux_user_config "$_cmux_user_config_home/fish/config.fish"
if not set -q CMUX_FISH_USER_CONFIG_ALREADY_LOADED; and test -n "$_cmux_user_config_home"; and test "$_cmux_user_config_home" != "$XDG_CONFIG_HOME"
    set -gx XDG_CONFIG_HOME "$_cmux_user_config_home"

    set -l _cmux_user_functions "$_cmux_user_config_home/fish/functions"
    if test -d "$_cmux_user_functions"; and not contains -- "$_cmux_user_functions" $fish_function_path
        set -g fish_function_path "$_cmux_user_functions" $fish_function_path
    end

    set -l _cmux_user_completions "$_cmux_user_config_home/fish/completions"
    if test -d "$_cmux_user_completions"; and not contains -- "$_cmux_user_completions" $fish_complete_path
        set -g fish_complete_path "$_cmux_user_completions" $fish_complete_path
    end

    for _cmux_user_conf in "$_cmux_user_config_home"/fish/conf.d/*.fish
        if test -r "$_cmux_user_conf"
            source "$_cmux_user_conf"
        end
    end

    if test -r "$_cmux_user_config"
        source "$_cmux_user_config"
    end
end
