public import CmuxNextDesign
public import CmuxNextIcons
public import Foundation

/// What a workspace's tab is (`SidebarTab.kind`).
public nonisolated enum SidebarTabKind: Hashable, Sendable, Codable {
    case terminal
    case browser
    case remoteTerminal
    case conversation
    /// A conversation tab on an acpmux session (an agent chat tab).
    case agentChat
    /// An agent session tab still on the New Tab page.
    case newTab
    case other(String)

    /// The kind's cmux icon.
    public var icon: IconName {
        switch self {
        case .terminal: .terminal
        case .browser: .browser
        case .remoteTerminal: .network
        case .conversation, .agentChat: .agentChat
        case .newTab: .tabNew
        case .other: .placeholder
        }
    }
}

/// One of a workspace's tabs, as the sidebar knows it (its row's title, tab count and hover card).
public nonisolated struct SidebarTab: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    public var kind: SidebarTabKind
    public var isUnread: Bool
    /// The brand id (CmuxAgentBrands) of the agent running in the tab or the chat's harness;
    /// the row draws its mark in place of the kind icon.
    public var brand: String?
    /// A browser tab's page favicon, drawn as is in the kind icon's place (cx-d0d.8).
    public var favicon: SidebarFavicon?
    /// The tab's own merged status (its OSC 7501 records, agent turn, page load): the tab bar's dot.
    public var state: StatusIndicatorState = .idle
    /// The tab's folder, shortened as the row's is ("~", "~/src/cmux").
    public var folder: String?
    /// What the tab's agent chat runs below its turn now (acpmux's `subagentsRunning` and
    /// `commandsRunning`): the hover card's tab row counts them (Leo 2026-11-01: "this hover
    /// preview being able to see the # of associated subagents and whatnot").
    public var subagentsRunning = 0
    public var commandsRunning = 0
    /// A browser tab's page host ("github.com"); nil for a blank page and every other kind.
    public var host: String?
    /// The terminal's git branch; nil outside a repository.
    public var branch: String?
    /// The tab's newest agent update or notification; nil without one.
    public var lastActivity: Date?
    /// A browser tab's page path after its host ("/manaflow-ai/cmux/pull/12"), no query; nil for "/" and other kinds.
    public var path: String?
    /// The model an agent chat tab's turn runs on (acpmux's turn detail); nil for other tabs.
    public var model: String?
    /// The program a terminal tab runs now, as its title names it; nil at the prompt.
    public var command: String?
    /// The machine the tab runs on when it is not its workspace's (a remote terminal's session);
    /// nil when the tab runs where its workspace does. The hover card names the workspace's otherwise.
    public var machine: String?

    public init(id: TabID, title: String, kind: SidebarTabKind = .terminal, isUnread: Bool = false, brand: String? = nil,
                favicon: SidebarFavicon? = nil, folder: String? = nil, state: StatusIndicatorState = .idle,
                host: String? = nil, branch: String? = nil, lastActivity: Date? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isUnread = isUnread
        self.brand = brand
        self.favicon = favicon
        self.folder = folder
        self.state = state
        self.host = host
        self.branch = branch
        self.lastActivity = lastActivity
    }
}
