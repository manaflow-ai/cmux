public struct ControlPaneInfo: Sendable, Hashable {
    public var id: String
    public var handle: String
    public var name: String?
    public var selectedTabID: String?
    public var tabs: [ControlTabInfo]
    public var tabGroups: [ControlTabGroupInfo]

    public init(id: String, handle: String, name: String? = nil, selectedTabID: String? = nil,
                tabs: [ControlTabInfo] = [], tabGroups: [ControlTabGroupInfo] = []) {
        self.id = id
        self.handle = handle
        self.name = name
        self.selectedTabID = selectedTabID
        self.tabs = tabs
        self.tabGroups = tabGroups
    }
}

/// One tab. Terminal metadata (`read-screen` needs size, title, cwd) is
/// here; screen contents stay in the daemon.
public struct ControlTabInfo: Sendable, Hashable {
    public var id: String
    /// Daemon surface handle.
    public var surface: String
    /// `terminal` or `browser`.
    public var kind: String
    public var title: String
    public var name: String?
    public var terminalID: String?
    /// Public terminal id (`term_…`) on registry daemons.
    public var terminalResourceID: String?
    public var columns: Int?
    public var rows: Int?
    public var cwd: String?
    public var url: String?
    public var gitBranch: String?
    public var isPinned: Bool
    public var isDead: Bool
    public var hasUnread: Bool
    public var tabGroupID: String?
    public var agentState: String?
    /// The agent running in the tab (`claude`, `codex`), when known.
    public var agent: String?
    /// A remote-terminal tab's terminal: its session (`registry_id`) and
    /// host terminal id there (data-model.md 1.2b).
    public var remoteSessionID: String?
    public var remoteTerminalID: String?
    /// A browser tab's browser profile id (`default` or a lowercase UUID); nil for other tabs.
    public var browserProfileID: String?
    /// An agent chat tab's acpmux session (`agent-session-tabs-v1`); nil for other tabs.
    public var agentSessionID: String?

    public init(id: String, surface: String, kind: String, title: String, name: String? = nil, terminalID: String? = nil,
                columns: Int? = nil, rows: Int? = nil, cwd: String? = nil, url: String? = nil, gitBranch: String? = nil,
                isPinned: Bool = false, isDead: Bool = false, hasUnread: Bool = false, tabGroupID: String? = nil,
                agentState: String? = nil) {
        self.id = id
        self.surface = surface
        self.kind = kind
        self.title = title
        self.name = name
        self.terminalID = terminalID
        self.columns = columns
        self.rows = rows
        self.cwd = cwd
        self.url = url
        self.gitBranch = gitBranch
        self.isPinned = isPinned
        self.isDead = isDead
        self.hasUnread = hasUnread
        self.tabGroupID = tabGroupID
        self.agentState = agentState
    }
}

public struct ControlTabGroupInfo: Sendable, Hashable {
    public var id: String
    public var name: String
    public var color: String?
    public var isCollapsed: Bool
    public var memberIDs: [String]

    public init(id: String, name: String, color: String?, isCollapsed: Bool, memberIDs: [String]) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.memberIDs = memberIDs
    }
}
