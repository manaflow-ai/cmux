public import CmuxNextDesign
public import Foundation

/// One place Go to Workspace (Cmd-P) can go besides a workspace: a sidebar
/// group, a pane or a tab of any kind. A value snapshot the App makes from
/// its mirror when the page opens.
public nonisolated struct PaletteNavigationEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A sidebar group; choosing it shows its first workspace.
        case group(workspaceCount: Int)
        case pane
        case tab(TabKind)
    }

    /// What a tab shows.
    public enum TabKind: String, Sendable, Hashable {
        case terminal
        case browser
        /// A terminal on another session (remote-terminal tab).
        case remoteTerminal
        case agentChat
        case markdown
        /// A file in the code editor page.
        case file
        /// Another internal page (App Store, Settings).
        case page
        case other
    }

    /// The object's id: a group, pane or tab id.
    public var id: String
    public var kind: Kind
    public var title: String
    /// The workspace that holds the pane or tab.
    public var workspaceTitle: String?
    /// The sidebar group of that workspace, or nil.
    public var groupTitle: String?
    public var cwd: String?
    public var url: String?
    /// The agent that runs in the tab (`claude`): its brand mark is drawn.
    public var agent: String?
    /// The session id Copy Session ID copies, also searchable: an acpmux
    /// chat's handle (`acp:<session id>`, what `cmux agent message` takes)
    /// or a Claude Code or Codex terminal's session UUID.
    public var sessionID: String?
    /// More words that find the row (a pane's tab titles).
    public var keywords: [String]
    /// A group's color, drawn as a ball.
    public var color: GroupColor?
    /// The focused pane or tab of the active window.
    public var isCurrent: Bool
    /// When the user last settled on it (the location trail), nil when never.
    public var lastUsed: Date?

    public init(id: String, kind: Kind, title: String, workspaceTitle: String? = nil, groupTitle: String? = nil,
                cwd: String? = nil, url: String? = nil, agent: String? = nil, sessionID: String? = nil, keywords: [String] = [],
                color: GroupColor? = nil, isCurrent: Bool = false, lastUsed: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.workspaceTitle = workspaceTitle
        self.groupTitle = groupTitle
        self.cwd = cwd
        self.url = url
        self.agent = agent
        self.sessionID = sessionID
        self.keywords = keywords
        self.color = color
        self.isCurrent = isCurrent
        self.lastUsed = lastUsed
    }

    /// The prefix `cmux agent message` reads as an acpmux session (`acp:<session id>`).
    public static let acpPrefix = "acp:"

    /// The palette item id: unique across kinds (a pane and a tab can share an id).
    public var itemID: String {
        switch kind {
        case .group: "group:\(id)"
        case .pane: "pane:\(id)"
        case .tab: "tab:\(id)"
        }
    }
}
