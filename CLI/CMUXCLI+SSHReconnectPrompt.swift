import CmuxFoundation
import Darwin
import Foundation

extension CMUXCLI {
    func sshAutoReconnectNoteFormat() -> String {
        let bundle = CLIExecutableLocator.enclosingAppBundle() ?? .main
        let status = String(localized: "cli.ssh.autoReconnect.status", defaultValue: "[cmux] ssh exited with status %s; reconnecting (attempt %s/%s).", bundle: bundle)
        let stopHint = String(localized: "cli.ssh.autoReconnect.stopHint", defaultValue: "[cmux] close this pane or press Ctrl-C to stop reconnecting.", bundle: bundle)
        return "\\n\\033[33m\(status)\\033[0m\\n\\033[2m\(stopHint)\\033[0m\\n"
    }

    /// Returns the localized success note printed after a transient SSH
    /// supervisor retry.  Keeping this beside the retry/error formats makes a
    /// historical warning in scrollback unambiguous once the bridge is live.
    func sshAutoReconnectRecoveredNoteFormat() -> String {
        let bundle = CLIExecutableLocator.enclosingAppBundle() ?? .main
        let status = String(
            localized: "cli.ssh.autoReconnect.recovered",
            defaultValue: "[cmux] SSH reconnected (attempt %s/%s).",
            bundle: bundle
        )
        return "\\n\\033[32m\(status)\\033[0m\\n"
    }

    func sshManualReconnectExitPromptFormat() -> String {
        let bundle = CLIExecutableLocator.enclosingAppBundle() ?? .main
        let status = String(localized: "cli.ssh.manualReconnectPrompt.status", defaultValue: "[cmux] ssh exited with status %s.", bundle: bundle)
        let detail = String(localized: "cli.ssh.manualReconnectPrompt.detail", defaultValue: "[cmux] the SSH connection ended; the remote session may still be running.", bundle: bundle)
        let prompt = String(localized: "cli.ssh.manualReconnectPrompt.prompt", defaultValue: "[cmux] press Enter to close this pane. Press r then Enter to reconnect.", bundle: bundle)
        return "\\n\\033[31m\(status)\\033[0m\\n\\033[2m\(detail)\\033[0m\\n\\033[2m\(prompt)\\033[0m\\n"
    }

    func sshTerminalExitPromptFormat() -> String {
        let bundle = CLIExecutableLocator.enclosingAppBundle() ?? .main
        let status = String(localized: "cli.ssh.manualReconnectPrompt.status", defaultValue: "[cmux] ssh exited with status %s.", bundle: bundle)
        let detail = String(localized: "cli.ssh.manualReconnectPrompt.detail", defaultValue: "[cmux] the SSH connection ended; the remote session may still be running.", bundle: bundle)
        let prompt = String(localized: "cli.ssh.terminalExitPrompt.prompt", defaultValue: "[cmux] press Enter to close this pane.", bundle: bundle)
        return "\\n\\033[31m\(status)\\033[0m\\n\\033[2m\(detail)\\033[0m\\n\\033[2m\(prompt)\\033[0m\\n"
    }

    /// Waits for a post-failure Enter without accepting queued terminal reports.
    func runSSHTerminalExitPrompt(commandArgs _: [String]) {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            parkSSHTerminalExitPromptAfterEOF()
        }

        var promptMode = original
        cfmakeraw(&promptMode)
        promptMode.c_lflag |= tcflag_t(ISIG)
        // Changing mode and flushing are one terminal operation: no byte queued
        // before this prompt boundary can later be mistaken for a fresh Enter.
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &promptMode) == 0 else {
            parkSSHTerminalExitPromptAfterEOF()
        }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        var inputFilter = SSHTerminalExitPromptInputFilter()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                if inputFilter.consume(Data(buffer.prefix(count))) {
                    return
                }
            } else if count == 0 {
                parkSSHTerminalExitPromptAfterEOF()
            } else if errno != EINTR {
                parkSSHTerminalExitPromptAfterEOF()
            }
        }
    }

    /// Keeps a dead input bridge from dismissing the pane while remaining signal-interruptible.
    private func parkSSHTerminalExitPromptAfterEOF() -> Never {
        while true {
            _ = Darwin.pause()
        }
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
