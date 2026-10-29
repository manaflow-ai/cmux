import Foundation

/// A cmux-next workspace on one Mac.
public struct Workspace: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var macID: String
    public var title: String
    public var directory: String
    public var branch: String?
    public var tabs: [WorkspaceTab]
    public var lastActivityAt: Date
    /// `lastActivityAt` is a real activity time. False for a live workspace
    /// with no activity seen since the phone connected: its time is only when
    /// the phone first listed it, so the list shows no time for it.
    public var hasActivityTime: Bool
    /// The Mac's focus order (higher = focused more recently; cmux-tui
    /// `focused_at`, a sequence, not a time). Orders rows with no activity time.
    public var focusOrder: Int
    /// The tab on screen on the Mac (the active screen's active pane's tab).
    public var activeTabID: String?
    public var needsAttention: Bool
    /// An agent in the workspace is working (row spinner).
    public var isWorking: Bool
    /// Something new arrived since this device last looked (row unread dot).
    public var hasUnread: Bool
    /// The cmux-next workspace color: a Mac palette name (`blue`, see
    /// `WorkspaceColor`) or `#RRGGBB`; and its icon (SF Symbol or one emoji).
    public var colorHex: String?
    public var icon: String?
    /// Pinned in the Mac's sidebar (its pinned section, else the legacy flag).
    public var isPinned: Bool = false
    /// The place in the pinned section on the Mac (its tile order).
    public var pinIndex: Int?
    /// The pinned tile's layout item, for Unpin (`sidebar_layout` item id).
    public var pinItemID: String?
    /// The place in the Mac's sidebar (its personal order, else the daemon's
    /// workspace order). Nil when the Mac's order is not known (mock data).
    public var sidebarIndex: Int?
    /// The workspace's public resource id on its Mac (`ws_…`), for layout refs.
    public var resourceID: String?
    /// The Mac shows a display name over the workspace's own name (its `title`
    /// field): Clear Workspace Name brings the own name back.
    public var hasCustomTitle: Bool = false
    /// The Mac's Home workspace (daemon `kind: "home"`): its tabs stay in it, as the Mac
    /// refuses to promote one ("Home's tabs stay in Home.").
    public var isHome: Bool = false
    /// The Mac's workspace group the workspace is in (its personal sidebar
    /// group, `list-personal`), if any.
    public var group: MacWorkspaceGroup?
    /// The workspace's panes on its Mac, from the Mac's live tree (never saved: a snapshot
    /// shows no Panes page until the Mac lists the workspace again).
    public var layout: WorkspaceLayout?
    /// The workspace's screens on the Mac, in its screen bar's order (`MacScreen`). Empty when
    /// the Mac's tree has not listed them (mock data, an old saved copy).
    public var screens: [MacScreen] = []

    public init(
        id: String, macID: String, title: String, directory: String, branch: String? = nil,
        tabs: [WorkspaceTab], lastActivityAt: Date, needsAttention: Bool = false,
        isWorking: Bool = false, hasUnread: Bool = false, colorHex: String? = nil, icon: String? = nil,
        hasActivityTime: Bool = true, focusOrder: Int = 0, activeTabID: String? = nil
    ) {
        self.hasActivityTime = hasActivityTime
        self.focusOrder = focusOrder
        self.activeTabID = activeTabID
        self.isWorking = isWorking
        self.hasUnread = hasUnread
        self.colorHex = colorHex
        self.icon = icon
        self.id = id
        self.macID = macID
        self.title = title
        self.directory = directory
        self.branch = branch
        self.tabs = tabs
        self.lastActivityAt = lastActivityAt
        self.needsAttention = needsAttention
    }
}

extension Workspace {
    enum CodingKeys: String, CodingKey {
        case id, macID, title, directory, branch, tabs, lastActivityAt, hasActivityTime, focusOrder, activeTabID
        case needsAttention, isWorking, hasUnread, colorHex, icon
        case isPinned, pinIndex, pinItemID, sidebarIndex, resourceID, hasCustomTitle, isHome, group, screens
    }

    /// Snapshots saved before a field existed still load (it takes its default).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            macID: try c.decode(String.self, forKey: .macID),
            title: try c.decode(String.self, forKey: .title),
            directory: try c.decode(String.self, forKey: .directory),
            branch: try c.decodeIfPresent(String.self, forKey: .branch),
            tabs: try c.decode([WorkspaceTab].self, forKey: .tabs),
            lastActivityAt: try c.decode(Date.self, forKey: .lastActivityAt),
            needsAttention: try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
            isWorking: try c.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false,
            hasUnread: try c.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false,
            colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex),
            icon: try c.decodeIfPresent(String.self, forKey: .icon),
            hasActivityTime: try c.decodeIfPresent(Bool.self, forKey: .hasActivityTime) ?? false,
            focusOrder: try c.decodeIfPresent(Int.self, forKey: .focusOrder) ?? 0,
            activeTabID: try c.decodeIfPresent(String.self, forKey: .activeTabID)
        )
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinIndex = try c.decodeIfPresent(Int.self, forKey: .pinIndex)
        pinItemID = try c.decodeIfPresent(String.self, forKey: .pinItemID)
        sidebarIndex = try c.decodeIfPresent(Int.self, forKey: .sidebarIndex)
        resourceID = try c.decodeIfPresent(String.self, forKey: .resourceID)
        hasCustomTitle = try c.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        isHome = try c.decodeIfPresent(Bool.self, forKey: .isHome) ?? false
        group = try c.decodeIfPresent(MacWorkspaceGroup.self, forKey: .group)
        screens = try c.decodeIfPresent([MacScreen].self, forKey: .screens) ?? []
    }
}

/// One tab inside a workspace.
public struct WorkspaceTab: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal, browser, agent
        /// A Mac phone tab showing an iOS simulator, streamed like a browser tab.
        case simulator
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// The agent harness for `.agent` tabs (claude, codex, ...).
    public var harness: String?
    /// Browser tabs: the page URL.
    public var url: URL?
    /// What the tab's agent is doing, when it runs one (an agent tab, or a
    /// terminal running Claude or Codex). Nil when idle or unknown.
    public var agentStatus: AgentStatus?
    /// What a `.waiting` agent waits for, when the Mac's acpmux says (agent tabs).
    /// Nil for a terminal agent, whose report says only that it is blocked.
    public var waitingFor: WaitingFor?
    /// Pinned on the Mac (`set-tab-pinned`): pinned tabs sort first in their pane.
    /// Optional so older saved copies still decode; nil reads as not pinned.
    public var pinned: Bool?
    /// The Mac tab group the tab is in (`tab_groups`), if any.
    public var group: TabGroupRef?

    /// What a cmux link can name this tab by (CmuxLink): the Mac's public ids.
    /// Nil when the Mac's tree did not carry them (mock data, an older Mac).
    public var linkIDs: LinkIDs?

    /// A tab's public ids on its Mac, as the Mac's Copy Link writes them.
    public struct LinkIDs: Hashable, Sendable, Codable {
        /// The tab's `tab_` resource id.
        public var tab: String?
        /// Its pane's `pane_` resource id.
        public var pane: String?
        /// The tab is its pane's selected tab (a pane link opens it).
        public var isPaneSelected: Bool
        /// The harness's own session id of the agent running in it (`list-agents`
        /// `agent_session_id`), which an `agent/<harness>/<session>` link names.
        public var harnessSession: String?

        public init(tab: String? = nil, pane: String? = nil, isPaneSelected: Bool = false, harnessSession: String? = nil) {
            self.tab = tab
            self.pane = pane
            self.isPaneSelected = isPaneSelected
            self.harnessSession = harnessSession
        }
    }

    public var isPinned: Bool { pinned == true }
    /// A terminal tab whose shell ended and that the Mac keeps (`dead`): Restart Shell
    /// Here gives it a new shell on the Mac. Optional so older saved copies still decode.
    public var shellEnded: Bool?
    public var hasEndedShell: Bool { kind == .terminal && shellEnded == true }

    /// A Mac tab group, as a member tab sees it.
    public struct TabGroupRef: Hashable, Sendable, Codable {
        public var id: String
        /// Empty: the Mac shows the color only.
        public var name: String
        public var color: String
        /// Saved ("Pin Group" on the Mac): `saved_id` is set.
        public var isSaved: Bool
        /// The group's icon on the Mac (`tab-group-icon-v1`): an SF Symbol or one emoji.
        public var icon: String?
        /// Collapsed in the Mac's tab strip (Collapse Tab Group).
        public var isCollapsed: Bool

        public init(id: String, name: String = "", color: String = "grey", isSaved: Bool = false, icon: String? = nil,
                    isCollapsed: Bool = false) {
            self.id = id
            self.name = name
            self.color = color
            self.isSaved = isSaved
            self.icon = icon
            self.isCollapsed = isCollapsed
        }

        enum CodingKeys: String, CodingKey { case id, name, color, isSaved, icon, isCollapsed }

        /// Copies saved before `icon` and `isCollapsed` existed still load.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                      color: try c.decodeIfPresent(String.self, forKey: .color) ?? "grey",
                      isSaved: try c.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false,
                      icon: try c.decodeIfPresent(String.self, forKey: .icon),
                      isCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false)
        }

        /// The Mac's group colors (`GroupColor.allCases`), in its menu's order.
        public static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

        /// A palette color's name as the Mac's menu shows it ("Grey"); a custom color reads "Custom".
        public static func colorTitle(_ token: String) -> String {
            colors.contains(token) ? token.prefix(1).uppercased() + token.dropFirst() : "Custom"
        }

        /// The Mac's next group color (`GroupColor.automatic`): the first of its automatic order
        /// not used in the pane, never blue or grey; grey when every one is used.
        public static func nextColor(used: Set<String>) -> String {
            ["red", "green", "yellow", "purple", "cyan", "orange", "pink"].first { !used.contains($0) } ?? "grey"
        }

        /// The group's name, else its color ("Red group"), as a phone line reads it.
        public var displayName: String {
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
            let color = color.hasPrefix("#") ? "Tab" : color.prefix(1).uppercased() + color.dropFirst()
            return "\(color) group"
        }
    }

    /// An agent's state as the Mac reports it.
    public enum AgentStatus: String, Hashable, Sendable, Codable {
        case working, waiting
    }

    /// What a waiting agent asks the person for.
    public enum WaitingFor: String, Hashable, Sendable, Codable {
        case permission, question
    }

    /// "<Agent> is asking permission", "<Agent> has a question", else "<Agent> is waiting".
    public var waitingPhrase: String {
        switch waitingFor {
        case .permission: "\(agentName) is asking permission"
        case .question: "\(agentName) has a question"
        case nil: "\(agentName) is waiting"
        }
    }

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, harness: String? = nil, url: URL? = nil,
                agentStatus: AgentStatus? = nil, waitingFor: WaitingFor? = nil, pinned: Bool? = nil, group: TabGroupRef? = nil) {
        self.pinned = pinned
        self.group = group
        self.url = url
        self.agentStatus = agentStatus
        self.waitingFor = waitingFor
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
    }

    /// Runs an agent (an agent tab, or a terminal with a known harness).
    public var isAgent: Bool { kind == .agent || harness != nil }

    /// "Claude", "Codex", else the harness capitalized, else "Agent".
    public var agentName: String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        case let other? where !other.isEmpty: other.prefix(1).uppercased() + other.dropFirst()
        default: "Agent"
        }
    }

    /// What the agent works on, for a status line: the tab's title unless it
    /// is only the agent's name, then its subtitle. Nil when neither says more.
    public var task: String? {
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title.caseInsensitiveCompare(agentName) != .orderedSame, title != harness { return title }
        let subtitle = subtitle?.trimmingCharacters(in: .whitespaces) ?? ""
        return subtitle.isEmpty ? nil : subtitle
    }

    public var systemImage: String {
        switch kind {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .simulator: "iphone"
        case .agent: "sparkle"
        }
    }
}
