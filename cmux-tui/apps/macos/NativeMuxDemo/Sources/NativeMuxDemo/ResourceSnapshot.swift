import Foundation

struct ResourceIdentity: Decodable, Sendable {
    let id: String
    let name: String?
}

struct WorkspaceSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let index: UInt32
    let focused: Bool
}

struct ScreenSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let workspaceID: String
    let name: String?
    let index: UInt32
    let focused: Bool
    let layout: LayoutDocument

    enum CodingKeys: String, CodingKey {
        case id, name, index, focused, layout
        case workspaceID = "workspace_id"
    }
}

struct PaneSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let screenID: String
    let name: String?
    let focused: Bool
    let zoomed: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, focused, zoomed
        case screenID = "screen_id"
    }
}

struct TabSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let paneID: String
    let name: String?
    let index: UInt32
    let focused: Bool
    let contentKind: String
    let contentID: String

    enum CodingKeys: String, CodingKey {
        case id, name, index, focused
        case paneID = "pane_id"
        case contentKind = "content_kind"
        case contentID = "content_id"
    }
}

struct TerminalSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let tabID: String
    let title: String
    let cols: UInt16
    let rows: UInt16
    let running: Bool
    let lifecycle: String

    enum CodingKeys: String, CodingKey {
        case id, title, cols, rows, running, lifecycle
        case tabID = "tab_id"
    }
}

struct BrowserSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let tabID: String
    let url: String
    let title: String
    let loading: Bool
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, url, title, loading, status
        case tabID = "tab_id"
    }
}

struct ResourceCursor: Decodable, Sendable {
    let generation: String
    let revision: String
}

struct ResourceSnapshot: Decodable, Sendable {
    let machine: ResourceIdentity
    let session: ResourceIdentity
    let workspaces: [WorkspaceSnapshot]
    let screens: [ScreenSnapshot]
    let panes: [PaneSnapshot]
    let tabs: [TabSnapshot]
    let terminals: [TerminalSnapshot]
    let browsers: [BrowserSnapshot]
    let cursor: ResourceCursor

    private let screensByWorkspaceID: [String: [ScreenSnapshot]]
    private let panesByID: [String: PaneSnapshot]
    private let tabsByPaneID: [String: [TabSnapshot]]
    private let terminalsByID: [String: TerminalSnapshot]
    private let browsersByID: [String: BrowserSnapshot]

    private enum CodingKeys: String, CodingKey {
        case machine, session, workspaces, screens, panes, tabs, terminals, browsers, cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machine = try container.decode(ResourceIdentity.self, forKey: .machine)
        session = try container.decode(ResourceIdentity.self, forKey: .session)
        workspaces = try container.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        screens = try container.decode([ScreenSnapshot].self, forKey: .screens)
        panes = try container.decode([PaneSnapshot].self, forKey: .panes)
        tabs = try container.decode([TabSnapshot].self, forKey: .tabs)
        terminals = try container.decode([TerminalSnapshot].self, forKey: .terminals)
        browsers = try container.decode([BrowserSnapshot].self, forKey: .browsers)
        cursor = try container.decode(ResourceCursor.self, forKey: .cursor)
        screensByWorkspaceID = Dictionary(grouping: screens, by: \.workspaceID)
            .mapValues { $0.sorted { $0.index < $1.index } }
        panesByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        tabsByPaneID = Dictionary(grouping: tabs, by: \.paneID)
            .mapValues { $0.sorted { $0.index < $1.index } }
        terminalsByID = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
        browsersByID = Dictionary(uniqueKeysWithValues: browsers.map { ($0.id, $0) })
    }

    func screens(in workspaceID: String) -> [ScreenSnapshot] {
        screensByWorkspaceID[workspaceID] ?? []
    }

    func pane(_ id: String) -> PaneSnapshot? {
        panesByID[id]
    }

    func tabs(in paneID: String) -> [TabSnapshot] {
        tabsByPaneID[paneID] ?? []
    }

    func terminal(for tab: TabSnapshot) -> TerminalSnapshot? {
        terminalsByID[tab.contentID]
    }

    func browser(for tab: TabSnapshot) -> BrowserSnapshot? {
        browsersByID[tab.contentID]
    }
}
