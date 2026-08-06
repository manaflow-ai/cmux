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

    func screens(in workspaceID: String) -> [ScreenSnapshot] {
        screens.filter { $0.workspaceID == workspaceID }.sorted { $0.index < $1.index }
    }

    func pane(_ id: String) -> PaneSnapshot? {
        panes.first { $0.id == id }
    }

    func tabs(in paneID: String) -> [TabSnapshot] {
        tabs.filter { $0.paneID == paneID }.sorted { $0.index < $1.index }
    }

    func terminal(for tab: TabSnapshot) -> TerminalSnapshot? {
        terminals.first { $0.id == tab.contentID }
    }

    func browser(for tab: TabSnapshot) -> BrowserSnapshot? {
        browsers.first { $0.id == tab.contentID }
    }
}
