public import CmuxNextDaemon
import Foundation

/// The name a workspace made from dragged or moved tabs takes (Lawrence,
/// 2026-10-02: "workspace name should be adopted from the name of the tab
/// that was dragged out"). Pure, so every case is tested; the one shared
/// path `TabMoves.toNewWorkspace` (drag, tear-off, palette, CLI, Move Pane)
/// and `TabGroupMoves.toNewWorkspace` apply it.
public nonisolated struct NewWorkspaceName {
    public init() {}

    /// What the rule reads from one tab.
    public struct Tab: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case terminal, browser, remoteTerminal
            /// A conversation, page or app tab (a Home conversation, Settings, a file viewer, an
            /// app): its record's title is the `about:blank` placeholder, so `title` is the name
            /// the tab shows of its own, nil when it has none (a New Tab page, a chat, an
            /// untitled Home conversation). It never falls back to a folder.
            case page
        }
        public var kind: Kind
        /// The name the user gave the tab.
        public var userName: String?
        /// The terminal's live title (OSC 0/2), or the browser record's title.
        public var title: String?
        /// A browser's live page title (the page the app renders).
        public var pageTitle: String?
        public var url: String?
        public var cwd: String?

        public init(kind: Kind, userName: String?, title: String?, pageTitle: String?, url: String?, cwd: String?) {
            self.kind = kind
            self.userName = userName
            self.title = title
            self.pageTitle = pageTitle
            self.url = url
            self.cwd = cwd
        }
    }

    public static let maxLength = 80

    /// The name for a workspace made from `tab`, or nil to keep the
    /// daemon's default. Order: the tab's user name, then a browser's page
    /// title (else its host), or a terminal's live title (a bare shell name
    /// such as "zsh" reads as the directory instead), then the directory.
    public static func forTab(_ tab: Tab) -> String? {
        if let name = clean(tab.userName) { return name }
        switch tab.kind {
        case .browser:
            let host = tab.url.flatMap(URL.init(string:))?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            for candidate in [tab.pageTitle, tab.title] {
                guard let title = clean(candidate), title != clean(tab.url) else { continue }
                return title
            }
            return clean(host)
        case .page:
            return clean(tab.title).flatMap { isPlaceholder($0) ? nil : $0 }
        case .terminal, .remoteTerminal:
            // An agent's spinner glyphs (`⠐ Fix the bug`) are status, not the name.
            if let title = clean(tab.title.map { TerminalTitle(raw: $0).text }), !isBareShell(title), !isPlaceholder(title) { return title }
            let directory = tab.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            return clean(directory == "/" ? nil : directory)
        }
    }

    /// The name for a workspace made from the last tab of another one
    /// (coordinator decision 2026-10-03): the old workspace's name when the
    /// user named it, else the tab's name.
    public static func forLastTab(workspaceName: String, workspaceTitle: String?, tab: Tab) -> String? {
        forLastTab(workspaceName: workspaceName, workspaceTitle: workspaceTitle, tabName: forTab(tab))
    }

    /// `forLastTab` with the tab's name already read (an agent chat's comes from its chat).
    public static func forLastTab(workspaceName: String, workspaceTitle: String?, tabName: String?,
                                  workspaceNameSource: WorkspaceNameSource = .auto, workspaceNameRevision: UInt64 = 0,
                                  allowsLegacyDefaults: Bool = true) -> String? {
        if let title = clean(workspaceTitle) { return title }
        let createdDefault = workspaceNameRevision == 0 && WorkspaceModel.isNumberedDefaultName(workspaceName)
        if workspaceNameSource == .user && !createdDefault && (workspaceNameRevision > 0 || !allowsLegacyDefaults),
           let name = clean(workspaceName) { return name }
        if !isDefaultWorkspaceName(workspaceName), let name = clean(workspaceName) { return name }
        return tabName
    }

    /// True for a name the daemon gave (`workspace-N`, its default; `WorkspaceModel.isDefaultName`).
    public static func isDefaultWorkspaceName(_ name: String) -> Bool { WorkspaceModel.isDefaultName(name) }

    /// The name for a workspace made from a tab group: its name, else its
    /// first tab's.
    public static func forGroup(name: String?, firstTab: Tab?) -> String? {
        clean(name) ?? firstTab.flatMap(forTab)
    }

    /// Shell names a terminal reports as its title while idle; they say
    /// nothing about the work, so the directory names the workspace.
    /// The blank page's and the New Tab page's addresses: what a conversation, page or app tab's
    /// record carries as its title, never a name.
    private static let placeholders: Set<String> = ["about:blank", "chrome://newtab", "chrome://newtab/"]

    private static func isPlaceholder(_ title: String) -> Bool {
        placeholders.contains(title.lowercased())
    }

    private static func isBareShell(_ title: String) -> Bool {
        TerminalTitle.isBareShell(title)
    }

    /// One line, trimmed, at most `maxLength` characters; nil when empty
    /// (`WorkspaceAutoName` names a workspace with it too).
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : String(line.prefix(maxLength))
    }
}
