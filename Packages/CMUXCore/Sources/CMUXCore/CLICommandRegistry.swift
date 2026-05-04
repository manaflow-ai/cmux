import Foundation

public enum CLICommandRoute: String, Sendable {
    case local
    case defaultSocket
}

public struct CLICommandDescriptor: Equatable, Sendable {
    public let name: String
    public let route: CLICommandRoute

    public init(name: String, route: CLICommandRoute) {
        self.name = name
        self.route = route
    }
}

public enum CLICommandRegistry {
    public static let descriptors: [CLICommandDescriptor] =
        localCommands.map { CLICommandDescriptor(name: $0, route: .local) } +
        defaultSocketCommands.map { CLICommandDescriptor(name: $0, route: .defaultSocket) }

    public static func canonicalName(for command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return descriptorByName[normalized]?.name
    }

    public static func contains(_ command: String) -> Bool {
        canonicalName(for: command) != nil
    }

    public static func descriptor(for command: String) -> CLICommandDescriptor? {
        guard let name = canonicalName(for: command) else { return nil }
        return descriptorByName[name]
    }

    private static let descriptorByName: [String: CLICommandDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })

    private static let localCommands = [
        "help",
        "version",
        "welcome",
        "shortcuts",
        "restore-session",
        "feedback",
        "themes",
        "claude-teams",
        "omo",
        "omx",
        "omc",
        "codex",
        "opencode",
        "cursor",
        "gemini",
        "copilot",
        "codebuddy",
        "factory",
        "qoder",
        "feed",
        "setup-hooks",
        "uninstall-hooks",
        "remote-daemon-status",
    ]

    private static let defaultSocketCommands = [
        "ping",
        "capabilities",
        "auth",
        "rpc",
        "identify",
        "list-windows",
        "current-window",
        "new-window",
        "focus-window",
        "close-window",
        "move-workspace-to-window",
        "move-surface",
        "reorder-surface",
        "reorder-workspace",
        "workspace-action",
        "tab-action",
        "rename-tab",
        "list-workspaces",
        "ssh",
        "ssh-session-end",
        "new-workspace",
        "new-split",
        "list-panes",
        "list-pane-surfaces",
        "tree",
        "focus-pane",
        "new-pane",
        "new-surface",
        "close-surface",
        "drag-surface-to-split",
        "refresh-surfaces",
        "reload-config",
        "surface-health",
        "debug-terminals",
        "trigger-flash",
        "list-panels",
        "focus-panel",
        "close-workspace",
        "select-workspace",
        "rename-workspace",
        "rename-window",
        "current-workspace",
        "read-screen",
        "send",
        "send-key",
        "send-panel",
        "send-key-panel",
        "notify",
        "list-notifications",
        "clear-notifications",
        "set-status",
        "clear-status",
        "list-status",
        "set-progress",
        "clear-progress",
        "log",
        "clear-log",
        "list-log",
        "sidebar-state",
        "set-app-focus",
        "simulate-app-active",
        "claude-hook",
        "feed-hook",
        "codex-hook",
        "opencode-hook",
        "cursor-hook",
        "gemini-hook",
        "copilot-hook",
        "codebuddy-hook",
        "factory-hook",
        "qoder-hook",
        "__tmux-compat",
        "capture-pane",
        "resize-pane",
        "pipe-pane",
        "wait-for",
        "swap-pane",
        "break-pane",
        "join-pane",
        "next-window",
        "previous-window",
        "last-window",
        "last-pane",
        "find-window",
        "clear-history",
        "set-hook",
        "popup",
        "bind-key",
        "unbind-key",
        "copy-mode",
        "set-buffer",
        "paste-buffer",
        "list-buffers",
        "respawn-pane",
        "display-message",
        "browser",
        "open-browser",
        "navigate",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "get-url",
        "focus-webview",
        "is-webview-focused",
        "markdown",
    ]
}
