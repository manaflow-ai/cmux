# cmux shell integration for nushell
# Sourced automatically by the cmux nushell bootstrap; do not source manually.
#
# Feature parity target is the fish integration
# (Resources/shell-integration/fish/config.fish): socket reporting of tty,
# shell activity state, pwd changes, and port-scan kicks, plus the claude/grok
# CLI wrappers, scrollback restore, and the keyboard-protocol reset. The
# zsh-only extras (git-branch probes, PR polling, Ghostty job-table patching)
# are intentionally not replicated here.
#
# State lives in _CMUX_* environment variables because nushell hook closures
# cannot mutate the environment; cmux registers string hooks that call the
# `def --env` entry points below, so mutations persist across prompts.

def _cmux_integration_enabled [] {
    ($env.CMUX_SHELL_INTEGRATION? | default "1") != "0"
}

def _cmux_pick_send_tool [] {
    if (which ncat | is-not-empty) {
        "ncat"
    } else if (which socat | is-not-empty) {
        "socat"
    } else if (which nc | is-not-empty) {
        "nc"
    } else {
        ""
    }
}

def --env _cmux_socket_is_unix [] {
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return false }
    if not ($sock | str starts-with "/") { return false }
    # The probe forks /bin/test and this runs from every prompt hook, so cache
    # the positive result for the session (the socket path is session-stable).
    # A negative result is not cached: the socket may come up moments later.
    if ($env._CMUX_SOCKET_IS_UNIX? | default "") == $"yes:($sock)" { return true }
    let live = ((^/bin/test -S $sock | complete | get exit_code) == 0)
    if $live { $env._CMUX_SOCKET_IS_UNIX = $"yes:($sock)" }
    $live
}

def _cmux_relay_cli_path [] {
    let bundled = ($env.CMUX_BUNDLED_CLI_PATH? | default "")
    if ($bundled != "") and ($bundled | path exists) { return $bundled }
    which cmux | get -o 0.path | default ""
}

def _cmux_socket_uses_remote_relay [] {
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return false }
    if ($sock | str starts-with "/") { return false }
    if not ($sock | str contains ":") { return false }
    (_cmux_relay_cli_path) != ""
}

def _cmux_send [payload: string] {
    if ($payload | is-empty) { return }
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return }
    let tool = ($env._CMUX_SEND_TOOL? | default "")
    let line = $"($payload)(char nl)"
    if $tool == "ncat" {
        $line | ^ncat -w 1 -U $sock --send-only | complete | ignore
    } else if $tool == "socat" {
        $line | ^socat -T 1 - $"UNIX-CONNECT:($sock)" | complete | ignore
    } else if $tool == "nc" {
        let first = ($line | ^nc -N -U $sock | complete)
        if $first.exit_code != 0 {
            $line | ^nc -w 1 -U $sock | complete | ignore
        }
    }
}

def _cmux_send_bg [payload: string] {
    if ($env.CMUX_TEST_SYNC_SEND? | default "") == "1" {
        _cmux_send $payload
        return
    }
    job spawn { _cmux_send $payload } | ignore
}

def _cmux_json_escape [value: string] {
    $value
    | str replace -a "\\" "\\\\"
    | str replace -a '"' '\"'
    | str replace -a "\n" "\\n"
    | str replace -a "\r" "\\r"
    | str replace -a "\t" "\\t"
}

def _cmux_relay_workspace_id [] {
    let workspace = ($env.CMUX_WORKSPACE_ID? | default "")
    if $workspace != "" { return $workspace }
    $env.CMUX_TAB_ID? | default ""
}

def _cmux_relay_rpc_bg [method: string, params: string] {
    let cli = (_cmux_relay_cli_path)
    if ($cli | is-empty) { return }
    if ($env.CMUX_TEST_SYNC_SEND? | default "") == "1" {
        ^$cli rpc $method $params | complete | ignore
        return
    }
    job spawn { ^$cli rpc $method $params | complete | ignore } | ignore
}

def _cmux_relay_params [pairs: record] {
    mut params = ($pairs | to json --raw)
    $params
}

def _cmux_report_tty_via_relay [] {
    if not (_cmux_socket_uses_remote_relay) { return }
    let name = ($env._CMUX_TTY_NAME? | default "")
    if ($name | is-empty) { return }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return }
    mut payload = {workspace_id: $workspace, tty_name: $name}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.report_tty ($payload | to json --raw)
}

def _cmux_report_pwd_via_relay [pwd: string] {
    if not (_cmux_socket_uses_remote_relay) { return false }
    if ($pwd | is-empty) { return false }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return false }
    mut payload = {workspace_id: $workspace, path: $pwd}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.report_pwd ($payload | to json --raw)
    true
}

def _cmux_ports_kick_via_relay [reason: string] {
    if not (_cmux_socket_uses_remote_relay) { return }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return }
    mut payload = {workspace_id: $workspace, reason: $reason}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.ports_kick ($payload | to json --raw)
}

def --env _cmux_report_tty_once [] {
    if ($env._CMUX_TTY_REPORTED? | default "") == "1" { return }
    mut name = ($env._CMUX_TTY_NAME? | default "")
    if ($name | is-empty) {
        let probe = (^tty | complete)
        if $probe.exit_code == 0 {
            $name = ($probe.stdout | str trim | str replace -r '^.*/' '')
        }
    }
    if ($name | is-empty) or ($name == "not a tty") { return }
    $env._CMUX_TTY_NAME = $name
    if (_cmux_socket_is_unix) {
        let tab = ($env.CMUX_TAB_ID? | default "")
        if ($tab | is-empty) { return }
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        $env._CMUX_TTY_REPORTED = "1"
        _cmux_send_bg $"report_tty ($name) --tab=($tab) --panel=($panel)"
    } else if (_cmux_socket_uses_remote_relay) {
        $env._CMUX_TTY_REPORTED = "1"
        _cmux_report_tty_via_relay
    }
}

def --env _cmux_report_shell_activity_state [state: string] {
    if ($state | is-empty) { return }
    # Dedupe before the socket probe: this runs on every prompt and the
    # state is unchanged almost every time.
    if ($env._CMUX_SHELL_ACTIVITY_LAST? | default "") == $state { return }
    if not (_cmux_socket_is_unix) { return }
    let tab = ($env.CMUX_TAB_ID? | default "")
    if ($tab | is-empty) { return }
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if ($panel | is-empty) { return }
    $env._CMUX_SHELL_ACTIVITY_LAST = $state
    _cmux_send_bg $"report_shell_state ($state) --tab=($tab) --panel=($panel)"
}

def --env _cmux_report_pwd_if_changed [] {
    let pwd = $env.PWD
    if $pwd == ($env._CMUX_PWD_LAST_PWD? | default "") { return }
    if (_cmux_socket_is_unix) {
        let tab = ($env.CMUX_TAB_ID? | default "")
        if ($tab | is-empty) { return }
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        let qpwd = (_cmux_json_escape $pwd)
        _cmux_send_bg $"report_pwd \"($qpwd)\" --tab=($tab) --panel=($panel)"
        $env._CMUX_PWD_LAST_PWD = $pwd
    } else if (_cmux_report_pwd_via_relay $pwd) {
        $env._CMUX_PWD_LAST_PWD = $pwd
    }
}

def --env _cmux_ports_kick [reason: string] {
    mut why = $reason
    if ($why | is-empty) { $why = "command" }
    let tab = ($env.CMUX_TAB_ID? | default "")
    if ($tab | is-empty) { return }
    $env._CMUX_PORTS_LAST_RUN = (date now | format date "%s")
    if (_cmux_socket_is_unix) {
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        _cmux_send_bg $"ports_kick --tab=($tab) --panel=($panel) --reason=($why)"
    } else {
        _cmux_ports_kick_via_relay $why
    }
}

def _cmux_reset_terminal_keyboard_protocols [] {
    let forced = ($env.CMUX_TEST_FORCE_KEYBOARD_RESET? | default "") + ($env.CMUX_TEST_FORCE_KITTY_RESET? | default "")
    if ($forced | is-empty) and not (is-terminal --stdout) { return }
    print -n "\e[>m\e[<8u"
}

def --env _cmux_restore_scrollback_once [] {
    let path = ($env.CMUX_RESTORE_SCROLLBACK_FILE? | default "")
    if ($path | is-empty) { return }
    hide-env CMUX_RESTORE_SCROLLBACK_FILE
    let token = ($path | str replace -r '^.*/' '')
    let host = (^/bin/hostname | complete | get stdout | str trim)
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)/.cmux/session-scrollback-replay/($token)/start\u{07}"
    if ($path | path exists) {
        try { ^/bin/cat -- $path }
        ^/bin/rm -f -- $path | complete | ignore
    }
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)/.cmux/session-scrollback-replay/($token)/end\u{07}"
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)($env.PWD)\u{07}"
}

def _cmux_wrapper_path [wrapper_file: string] {
    let dir = ($env.CMUX_SHELL_INTEGRATION_DIR? | default "")
    if ($dir | is-empty) { return "" }
    let bundle = ($dir | str replace -r '/shell-integration/?$' '')
    let candidate = ($bundle | path join "bin" $wrapper_file)
    if ($candidate | path exists) { $candidate } else { "" }
}

# Route `claude` through the cmux wrapper so session tracking and
# notification hooks are injected even if later PATH edits shadow the
# per-surface shim. `^claude` resolves the real external through PATH.
def --wrapped claude [...args: string] {
    let shim = ($env.CMUX_CLAUDE_WRAPPER_SHIM? | default "")
    if ($shim != "") and ($shim | path exists) {
        ^$shim ...$args
    } else {
        let wrapper = (_cmux_wrapper_path "cmux-claude-wrapper")
        if ($wrapper != "") {
            ^$wrapper ...$args
        } else {
            ^claude ...$args
        }
    }
}

def --wrapped grok [...args: string] {
    let wrapper = (_cmux_wrapper_path "grok")
    if ($wrapper != "") {
        ^$wrapper ...$args
    } else {
        ^grok ...$args
    }
}

def --env _cmux_pre_execution [] {
    if not (_cmux_integration_enabled) { return }
    _cmux_report_tty_once
    _cmux_report_shell_activity_state running
    _cmux_ports_kick command
}

def --env _cmux_pre_prompt [] {
    if not (_cmux_integration_enabled) { return }
    _cmux_reset_terminal_keyboard_protocols
    _cmux_report_tty_once
    _cmux_report_shell_activity_state prompt
    _cmux_report_pwd_if_changed
    let now = (date now | format date "%s" | into int)
    let last = (($env._CMUX_PORTS_LAST_RUN? | default "0") | into int)
    if ($now - $last) >= 5 { _cmux_ports_kick refresh }
}

if (_cmux_integration_enabled) {
    $env._CMUX_SEND_TOOL = (_cmux_pick_send_tool)
    _cmux_restore_scrollback_once
    # String hooks (not closures) so the def --env entry points can persist
    # their dedupe state into the REPL environment.
    $env.config = ($env.config | upsert hooks.pre_execution (
        ($env.config.hooks.pre_execution? | default []) | append "_cmux_pre_execution"
    ))
    $env.config = ($env.config | upsert hooks.pre_prompt (
        ($env.config.hooks.pre_prompt? | default []) | append "_cmux_pre_prompt"
    ))
}
