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
}
