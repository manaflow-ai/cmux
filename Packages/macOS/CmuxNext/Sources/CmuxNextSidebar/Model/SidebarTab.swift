public import CmuxNextDesign
public import CmuxNextIcons
import Foundation

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

    public init(id: TabID, title: String, kind: SidebarTabKind = .terminal, isUnread: Bool = false, brand: String? = nil,
                favicon: SidebarFavicon? = nil, folder: String? = nil, state: StatusIndicatorState = .idle) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isUnread = isUnread
        self.brand = brand
        self.favicon = favicon
        self.folder = folder
        self.state = state
    }
}
