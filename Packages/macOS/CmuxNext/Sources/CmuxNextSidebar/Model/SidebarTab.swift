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

/// A tab that can optionally be listed below its workspace.
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
    /// The program's own status words (OSC 7501), when it reports any.
    public var words: String?
    /// The agent running in the tab ("Claude Code"), when cmux lists it.
    public var agent: String?
    /// A page's host, without `www.`.
    public var host: String?
    /// The tab's folder, shortened as the row's is ("~", "~/src/cmux").
    public var folder: String?
    /// The folder is the workspace's own: the line's detail leaves it out (every tab would repeat it); a
    /// title that only names it still reads as untitled.
    public var sharesWorkspaceFolder = false
    /// Its workspace's own name (the user's title, else the daemon's name), which the tab's line does not
    /// repeat. Not the row's shown title, which may follow a page or the selected tab.
    public var workspaceName: String?

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
