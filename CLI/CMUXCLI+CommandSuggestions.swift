import Foundation

extension CMUXCLI {
    /// Verbs that only drove features of the deleted legacy app. They keep a
    /// typed error, so scripts learn why instead of seeing "Unknown command".
    static let removedCommandReasons: [String: String] = [
        "canvas": "canvas layout was removed",
        "debug-terminals": "debug methods of the old app are not part of cmux-next",
        "iroh-diag": "Iroh diagnostics of the old app are not part of cmux-next",
        "ios": "the simulator pane is not part of cmux-next",
        "project": "the project pane is not part of cmux-next",
        "refresh-surfaces": "there is nothing to refresh",
        "right-sidebar": "the right sidebar is not part of cmux-next",
        "set-app-focus": "focus overrides were a debug feature of the old app",
        "simulate-app-active": "focus overrides were a debug feature of the old app",
        "simulate-sidebar-drag": "debug methods of the old app are not part of cmux-next",
        "simulator": "the simulator pane is not part of cmux-next",
    ]

    func removedCommandError(_ command: String) -> CLIError? {
        guard let reason = Self.removedCommandReasons[command] else { return nil }
        return CLIError(message: "unsupported in cmux-next: \(reason) (cmux \(command))")
    }

    func unknownCommandError(_ command: String) -> CLIError {
        var message = "Unknown command '\(command)'."
        if let suggestion = suggestedCommandName(for: command) {
            message += " Did you mean '\(suggestion)'?"
        }
        message += " Run 'cmux --help' for the full command list."
        return CLIError(message: message, exitCode: 2)
    }

    private func suggestedCommandName(for command: String) -> String? {
        var bestName: String?
        var bestDistance = Int.max

        for candidate in Self.topLevelCommandNames where !candidate.hasPrefix("__") {
            let distance = editDistance(command, candidate)
            guard distance > 0, distance <= 2, distance < candidate.count else { continue }
            if distance < bestDistance || (distance == bestDistance && candidate < (bestName ?? candidate)) {
                bestName = candidate
                bestDistance = distance
            }
        }

        return bestName
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[rightIndex + 1] = previous[rightIndex]
                } else {
                    current[rightIndex + 1] = min(min(previous[rightIndex + 1], current[rightIndex]), previous[rightIndex]) + 1
                }
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    static let topLevelCommandNames: Set<String> = [
        "__codex-teams-watch",
        "__tmux-compat",
        "action",
        "agent",
        "agent-hibernation",
        "ai-accounts",
        "automation",
        "auth",
        "bind-key",
        "break-pane",
        "browser",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "browser-status",
        "capabilities",
        "capture-pane",
        "claude-hook",
        "claude-teams",
        "clear-history",
        "clear-log",
        "clear-notifications",
        "clear-progress",
        "clear-status",
        "close-surface",
        "close-window",
        "close-workspace",
        "cloud",
        "coderouter",
        "cr",
        "codex",
        "codex-hook",
        "codex-teams",
        "comments",
        "config",
        "copy-mode",
        "current",
        "current-window",
        "current-workspace",
        "detach-tab",
        "diff",
        "disable-browser",
        "dismiss-notification",
        "display-message",
        "docs",
        "drag-surface-to-split",
        "enable-browser",
        "events",
        "feedback",
        "feed",
        "feed-hook",
        "fork",
        "find-window",
        "focus-pane",
        "focus-panel",
        "focus-webview",
        "focus-window",
        "get-url",
        "glaeda",
        "help",
        "hooks",
        "identify",
        "import",
        "is-webview-focused",
        "join-pane",
        "jump-to-unread",
        "last-pane",
        "last-window",
        "list-buffers",
        "list-log",
        "list-notifications",
        "list-pane-surfaces",
        "list-panels",
        "list-panes",
        "list-status",
        "list-windows",
        "list-workspaces",
        "log",
        "login",
        "logout",
        "local-tmux",
        "markdown",
        "mark-notification-read",
        "memory",
        "mobile",
        "mosh",
        "mosh-tmux",
        "move-surface",
        "move-tab-to-new-workspace",
        "move-workspace-to-window",
        "navigate",
        "new-pane",
        "new-split",
        "new-surface",
        "new-window",
        "new-workspace",
        "next-window",
        "notify",
        "omc",
        "omo",
        "omx",
        "open",
        "open-browser",
        "open-notification",
        "paste",
        "paste-buffer",
        "ping",
        "pipe-pane",
        "popup",
        "previous-window",
        "read-screen",
        "read-selection",
        "reload-config",
        "remote-daemon-status",
        "rename-tab",
        "rename-window",
        "rename-workspace",
        "reorder-surface",
        "reorder-workspace",
        "reorder-workspaces",
        "resize-pane",
        "resize-window",
        "respawn-pane",
        "restore-session",
        "restore",
        "rpc",
        "select-workspace",
        "send",
        "send-key",
        "send-key-panel",
        "send-panel",
        "session",
        "sessions",
        "set-buffer",
        "set-hook",
        "set-progress",
        "set-status",
        "settings",
        "setup-hooks",
        "shortcuts",
        "socket-status",
        "sidebar-state",
        "split-off",
        "ssh",
        "ssh-pty-attach",
        "ssh-session-attach",
        "ssh-session-cleanup",
        "ssh-session-end",
        "ssh-session-list",
        "ssh-tmux",
        "sudo",
        "surface",
        "surface-health",
        "surface-resume",
        "swap-pane",
        "tab-action",
        "themes",
        "tmux",
        "todo",
        "top",
        "tree",
        "trigger-flash",
        "unbind-key",
        "uninstall-hooks",
        "vault",
        "version",
        "vm",
        "vm-pty-attach",
        "vm-pty-connect",
        "vm-ssh-attach",
        "vm-tui-approve",
        "vm-tui-connect",
        "vpn",
        "wait-for",
        "welcome",
        "workspace",
        "workspace-action",
        "workspace-group",
    ]
}
