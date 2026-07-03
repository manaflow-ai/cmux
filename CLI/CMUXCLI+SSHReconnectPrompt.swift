import Foundation

extension CMUXCLI {
    func sshAutoReconnectNoteFormat() -> String {
        let status = String(localized: "cli.ssh.autoReconnect.status", defaultValue: "[cmux] ssh exited with status %s; reconnecting (attempt %s/%s).")
        let stopHint = String(localized: "cli.ssh.autoReconnect.stopHint", defaultValue: "[cmux] close this pane or press Ctrl-C to stop reconnecting.")
        return "\\n\\033[33m\(status)\\033[0m\\n\\033[2m\(stopHint)\\033[0m\\n"
    }

    func sshManualReconnectExitPromptFormat() -> String {
        let status = String(localized: "cli.ssh.manualReconnectPrompt.status", defaultValue: "[cmux] ssh exited with status %s.")
        let detail = String(localized: "cli.ssh.manualReconnectPrompt.detail", defaultValue: "[cmux] the remote VM may have been paused, destroyed, or lost network.")
        let prompt = String(localized: "cli.ssh.manualReconnectPrompt.prompt", defaultValue: "[cmux] press r then Enter to reconnect, or Enter to close this pane.")
        return "\\n\\033[31m\(status)\\033[0m\\n\\033[2m\(detail)\\033[0m\\n\\033[2m\(prompt)\\033[0m\\n"
    }

    func sshRemoteReconnectShellFunction() -> String {
        [
            "cmux_ssh_remote_reconnect() {",
            "  cmux_reconnect_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "  if [ -z \"$cmux_reconnect_cli\" ] || [ ! -x \"$cmux_reconnect_cli\" ]; then cmux_reconnect_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "  cmux_reconnect_socket=\"${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}\"",
            "  if [ -z \"$cmux_reconnect_cli\" ] || [ -z \"$cmux_reconnect_socket\" ] || [ -z \"${CMUX_WORKSPACE_ID:-}\" ]; then return 0; fi",
            "  cmux_reconnect_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\"\"",
            "  if [ -n \"${CMUX_SURFACE_ID:-}\" ]; then cmux_reconnect_payload=\"$cmux_reconnect_payload,\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\"\"; fi",
            "  cmux_reconnect_payload=\"$cmux_reconnect_payload}\"",
            "  \"$cmux_reconnect_cli\" --socket \"$cmux_reconnect_socket\" rpc workspace.remote.reconnect \"$cmux_reconnect_payload\" >/dev/null 2>&1",
            "}",
        ].joined(separator: "\n")
    }
}
