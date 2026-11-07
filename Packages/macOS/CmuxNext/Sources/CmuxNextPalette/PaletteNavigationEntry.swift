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
    /// That workspace's id: tabs that only repeat its name are told apart within it.
    public var workspaceID: String?
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
    /// The machine whose daemon holds the pane or tab; nil for this Mac's. Forks keep
    /// ids, so choosing the row acts on this machine's object only (cmux#30755).
    public var machineID: String?
    /// The sidebar place (0 is the top) of the row's workspace, or of a group's first workspace;
    /// nil when the sidebar does not draw it.
    public var sidebarRank: Int?

    public init(id: String, kind: Kind, title: String, workspaceTitle: String? = nil, workspaceID: String? = nil, groupTitle: String? = nil,
                cwd: String? = nil, url: String? = nil, agent: String? = nil, sessionID: String? = nil, keywords: [String] = [],
                color: GroupColor? = nil, isCurrent: Bool = false, lastUsed: Date? = nil, machineID: String? = nil,
                sidebarRank: Int? = nil) {
        self.sidebarRank = sidebarRank
        self.id = id
        self.kind = kind
        self.title = title
        self.workspaceTitle = workspaceTitle
        self.workspaceID = workspaceID
        self.groupTitle = groupTitle
        self.cwd = cwd
        self.url = url
        self.agent = agent
        self.sessionID = sessionID
        self.keywords = keywords
        self.color = color
        self.isCurrent = isCurrent
        self.lastUsed = lastUsed
        self.machineID = machineID
    }

    /// The record's title of a tab that names nothing a person reads (an agent chat, a Home
    /// conversation or a page carry `about:blank`; a new tab none), replaced by `title`, the name
    /// its tab shows (`TabTitleResolver`). Cmd-P listed agent chats as "about:blank" (msg 11943).
    public static func titled(_ entries: [PaletteNavigationEntry], title: (PaletteNavigationEntry) -> String?) -> [PaletteNavigationEntry] {
        entries.map { entry in
            guard case .tab = entry.kind, entry.title.isEmpty || entry.title == blankTitle,
                  let shown = title(entry), !shown.isEmpty else { return entry }
            var titled = entry
            titled.title = shown
            return titled
        }
    }

    /// The address a page-backed tab's record is titled with.
    public static let blankTitle = "about:blank"

    /// The prefix `cmux agent message` reads as an acpmux session (`acp:<session id>`).
    public static let acpPrefix = "acp:"

    /// The palette item id: unique across kinds (a pane and a tab can share an id).
    public var itemID: String {
        switch kind {
        case .group: "group:\(id)"
        // Another machine's pane is qualified by it: forks share pane ids (cmux#30755).
        case .pane: machineID.map { "pane:\($0):\(id)" } ?? "pane:\(id)"
        case .tab: "tab:\(id)"
        }
    }
}
