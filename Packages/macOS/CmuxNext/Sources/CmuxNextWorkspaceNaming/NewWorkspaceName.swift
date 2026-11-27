public import CmuxNextDaemon
import Foundation

/// The name a workspace made from dragged or moved tabs takes (Lawrence,
/// 2026-10-02: "workspace name should be adopted from the name of the tab
/// that was dragged out"). The rule is Rust's (`cmux-workspace-naming`, with its tests); the one shared
/// path `TabMoves.toNewWorkspace` (drag, tear-off, palette, CLI, Move Pane)
/// and `TabGroupMoves.toNewWorkspace` apply it.
public nonisolated struct NewWorkspaceName {
    public init() {}

    /// What the rule reads from one tab.
    public nonisolated struct Tab: Equatable, Sendable, Encodable {
        public nonisolated enum Kind: String, Equatable, Sendable, Encodable {
            case terminal, browser, remoteTerminal = "remote_terminal"
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
    /// such as "zsh" reads as the directory instead), then the directory
    /// (Rust `new_name::for_tab`).
    public static func forTab(_ tab: Tab) -> String? {
        WorkspaceNamingRules().string("for_tab", TabRequest(tab: tab), key: "name")
    }

    /// The name for a workspace made from the last tab of another one
    /// (coordinator decision 2026-10-03): the old workspace's name when the
    /// user named it, else the tab's name.
    public static func forLastTab(workspaceName: String, workspaceTitle: String?, tab: Tab) -> String? {
        WorkspaceNamingRules().string("for_last_tab", LastTabRequest(name: workspaceName, title: workspaceTitle, tab: tab), key: "name")
    }

    /// `forLastTab` with the tab's name already read (an agent chat's comes from its chat).
    public static func forLastTab(workspaceName: String, workspaceTitle: String?, tabName: String?,
                                  workspaceNameSource: WorkspaceNameSource = .auto, workspaceNameRevision: UInt64 = 0,
                                  allowsLegacyDefaults: Bool = true) -> String? {
        WorkspaceNamingRules().string("for_last_tab", LastTabRequest(
            name: workspaceName, title: workspaceTitle, source: workspaceNameSource, revision: workspaceNameRevision,
            allowsLegacyDefaults: allowsLegacyDefaults, tabName: tabName), key: "name")
    }

    /// True for a name the daemon gave (`workspace-N`, its default; `WorkspaceModel.isDefaultName`).
    public static func isDefaultWorkspaceName(_ name: String) -> Bool { WorkspaceModel.isDefaultName(name) }

    /// The name for a workspace made from a tab group: its name, else its
    /// first tab's.
    public static func forGroup(name: String?, firstTab: Tab?) -> String? {
        WorkspaceNamingRules().string("for_group", GroupRequest(name: name, firstTab: firstTab), key: "name")
    }

    /// One line, trimmed, at most `maxLength` characters; nil when empty
    /// (`WorkspaceAutoName` names a workspace with it too).
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return WorkspaceNamingRules().string("clean", TextRequest(text: raw), key: "name")
    }

    private nonisolated struct TabRequest: Encodable { var tab: Tab }
    private nonisolated struct GroupRequest: Encodable { var name: String?; var firstTab: Tab? }
    private nonisolated struct LastTabRequest: Encodable {
        var name: String
        var title: String?
        var source: WorkspaceNameSource = .auto
        var revision: UInt64 = 0
        var allowsLegacyDefaults = true
        var tabName: String?
        var tab: Tab?
    }
}

/// A request of one text.
nonisolated struct TextRequest: Encodable { var text: String? }
