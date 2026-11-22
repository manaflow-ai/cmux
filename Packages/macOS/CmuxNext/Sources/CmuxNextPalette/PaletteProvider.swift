

/// Supplies palette items. The palette asks every provider of a page when
/// the page opens (and after a keep-open command), then searches the items
/// locally, so providers return their whole candidate set and never see
/// keystrokes.
public protocol PaletteProvider: AnyObject {
    var id: String { get }
    /// Whether items appear before the user types. Dynamic sources on the
    /// root page (workspaces, tabs) set this false to keep the command list
    /// short; nested pages set it true.
    var showsItemsForEmptyQuery: Bool { get }
    /// Items available synchronously, used on open so the first frame is
    /// never empty. Nil means "call `items()`".
    var immediateItems: [PaletteItem]? { get }
    func items() async -> [PaletteItem]
}

extension PaletteProvider {
    public var showsItemsForEmptyQuery: Bool { true }
    public var immediateItems: [PaletteItem]? { nil }
}

/// A provider over a fixed item list (extensions, tests, custom actions).
public final class StaticPaletteProvider: PaletteProvider {
    public let id: String
    public var itemsList: [PaletteItem]
    public let showsItemsForEmptyQuery: Bool

    public init(id: String, items: [PaletteItem], showsItemsForEmptyQuery: Bool = true) {
        self.id = id
        self.itemsList = items
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public var immediateItems: [PaletteItem]? { itemsList }
    public func items() async -> [PaletteItem] { itemsList }
}

/// A provider backed by an async closure (daemon queries, file system scans).
public final class AsyncPaletteProvider: PaletteProvider {
    public let id: String
    public let showsItemsForEmptyQuery: Bool
    private let load: @MainActor () async -> [PaletteItem]

    public init(id: String, showsItemsForEmptyQuery: Bool = true, load: @escaping @MainActor () async -> [PaletteItem]) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.load = load
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public func items() async -> [PaletteItem] { await load() }
}
