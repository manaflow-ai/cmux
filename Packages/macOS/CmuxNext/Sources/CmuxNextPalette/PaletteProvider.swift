

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
    /// Cached rows draw immediately while this provider refreshes their state.
    var refreshesOnOpen: Bool { get }
    func items() async -> [PaletteItem]
    /// Items over time, for a source that shows a first list and a fuller one later (a notice
    /// row while a slow source answers, then its rows). Nil: `items()` once.
    func itemUpdates() -> AsyncStream<[PaletteItem]>?
}

extension PaletteProvider {
    public var showsItemsForEmptyQuery: Bool { true }
    public var immediateItems: [PaletteItem]? { nil }
    public var refreshesOnOpen: Bool { false }
    public func itemUpdates() -> AsyncStream<[PaletteItem]>? { nil }
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
    public let immediateItems: [PaletteItem]?
    public var refreshesOnOpen: Bool { immediateItems != nil }
    private let load: @MainActor () async -> [PaletteItem]
    private let updates: (@MainActor () -> AsyncStream<[PaletteItem]>)?

    public init(id: String, showsItemsForEmptyQuery: Bool = true, immediateItems: [PaletteItem]? = nil,
                load: @escaping @MainActor () async -> [PaletteItem]) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.immediateItems = immediateItems
        self.load = load
        self.updates = nil
    }

    /// A provider whose items come over time (``PaletteProvider/itemUpdates()``); `items()` is the last list.
    public static func streaming(id: String, showsItemsForEmptyQuery: Bool = true, immediateItems: [PaletteItem]? = nil,
                                 updates: @escaping @MainActor () -> AsyncStream<[PaletteItem]>) -> AsyncPaletteProvider {
        AsyncPaletteProvider(id: id, showsItemsForEmptyQuery: showsItemsForEmptyQuery, immediateItems: immediateItems,
                             streaming: updates)
    }

    private init(id: String, showsItemsForEmptyQuery: Bool, immediateItems: [PaletteItem]?,
                 streaming updates: @escaping @MainActor () -> AsyncStream<[PaletteItem]>) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.immediateItems = immediateItems
        self.updates = updates
        self.load = {
            var last: [PaletteItem] = []
            for await items in updates() { last = items }
            return last
        }
    }

    public func itemUpdates() -> AsyncStream<[PaletteItem]>? { updates?() }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public func items() async -> [PaletteItem] { await load() }
}
