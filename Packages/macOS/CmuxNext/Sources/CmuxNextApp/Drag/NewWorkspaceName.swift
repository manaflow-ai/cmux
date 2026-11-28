import Foundation

/// The name a workspace made from dragged or moved tabs takes (Lawrence,
/// 2026-10-02: "workspace name should be adopted from the name of the tab
/// that was dragged out"). Pure, so every case is tested; the one shared
/// path `TabMoves.toNewWorkspace` (drag, tear-off, palette, CLI, Move Pane)
/// and `TabGroupMoves.toNewWorkspace` apply it.
nonisolated enum NewWorkspaceName {
    /// What the rule reads from one tab.
    struct Tab: Equatable {
        enum Kind: Equatable { case terminal, browser, remoteTerminal }
        var kind: Kind
        /// The name the user gave the tab.
        var userName: String?
        /// The terminal's live title (OSC 0/2), or the browser record's title.
        var title: String?
        /// A browser's live page title (the page the app renders).
        var pageTitle: String?
        var url: String?
        var cwd: String?
    }

    static let maxLength = 80

    /// The name for a workspace made from `tab`, or nil to keep the
    /// daemon's default. Order: the tab's user name, then a browser's page
    /// title (else its host), or a terminal's live title (a bare shell name
    /// such as "zsh" reads as the directory instead), then the directory.
    static func forTab(_ tab: Tab) -> String? {
        if let name = clean(tab.userName) { return name }
        switch tab.kind {
        case .browser:
            let host = tab.url.flatMap(URL.init(string:))?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            for candidate in [tab.pageTitle, tab.title] {
                guard let title = clean(candidate), title != clean(tab.url) else { continue }
                return title
            }
            return clean(host)
        case .terminal, .remoteTerminal:
            if let title = clean(tab.title), !isBareShell(title) { return title }
            let directory = tab.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            return clean(directory == "/" ? nil : directory)
        }
    }

    /// The name for a workspace made from the last tab of another one
    /// (coordinator decision 2026-10-03): the old workspace's name when the
    /// user named it, else the tab's name.
    static func forLastTab(workspaceName: String, workspaceTitle: String?, tab: Tab) -> String? {
        if let title = clean(workspaceTitle) { return title }
        if !isDefaultWorkspaceName(workspaceName), let name = clean(workspaceName) { return name }
        return forTab(tab)
    }

    /// True for a name the daemon gave (`workspace-N`, its default).
    /// A user could name a workspace `workspace-7` by hand; the daemon
    /// records no "named by the user" flag, so that name reads as default.
    static func isDefaultWorkspaceName(_ name: String) -> Bool {
        guard name.hasPrefix("workspace-") else { return false }
        let number = name.dropFirst("workspace-".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// The name for a workspace made from a tab group: its name, else its
    /// first tab's.
    static func forGroup(name: String?, firstTab: Tab?) -> String? {
        clean(name) ?? firstTab.flatMap(forTab)
    }

    /// Shell names a terminal reports as its title while idle; they say
    /// nothing about the work, so the directory names the workspace.
    private static let bareShells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login"]

    private static func isBareShell(_ title: String) -> Bool {
        bareShells.contains(title.hasPrefix("-") ? String(title.dropFirst()) : title)
    }

    /// One line, trimmed, at most `maxLength` characters; nil when empty.
    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : String(line.prefix(maxLength))
    }
}
