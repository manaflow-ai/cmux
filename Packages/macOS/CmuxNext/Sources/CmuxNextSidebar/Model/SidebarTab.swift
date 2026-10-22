public import CmuxNextDesign
public import CmuxNextIcons
import Foundation

/// The kind icon used by an optional sidebar tab row.
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

/// A tab of a workspace: listed below its workspace when tab listing is enabled, and in the
/// workspace's hover card (u9696). Mapped once per change of the daemon's records with its row
/// (`SidebarMapping.row`), so a hover reads it and computes nothing.
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
    /// The tab's merged status (its OSC 7501 records, agent turn, page load): the tab bar's dot.
    public var state: StatusIndicatorState
    /// The hover card's second line: the program's own status words, else the folder (a terminal),
    /// the page's host (a browser), the agent (a chat). Nil when there is nothing to say.
    public var detail: String?
    /// The index of the tab's pane among the workspace's panes that hold tabs, in pane order.
    public var pane: UInt16
    /// A page's sound and sleep.
    public var flags: SidebarTabFlags

    public init(id: TabID, title: String, kind: SidebarTabKind = .terminal, isUnread: Bool = false, brand: String? = nil,
                favicon: SidebarFavicon? = nil, state: StatusIndicatorState = .idle, detail: String? = nil, pane: UInt16 = 0,
                flags: SidebarTabFlags = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isUnread = isUnread
        self.brand = brand
        self.favicon = favicon
        self.state = state
        self.detail = detail
        self.pane = pane
        self.flags = flags
    }
}
