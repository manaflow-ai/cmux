

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

    public var immediateItems: [PaletteItem]? { live(itemsList) }
    public func items() async -> [PaletteItem] { live(itemsList) }

    /// `items` with each on/off row's state read now (``PaletteItem/readsToggleState``).
    private func live(_ items: [PaletteItem]) -> [PaletteItem] {
        guard items.contains(where: { $0.readsToggleState != nil }) else { return items }
        return items.map { item in
            guard let read = item.readsToggleState else { return item }
            var item = item
            let isOn = read()
            guard isOn != item.toggleState else { return item }
            item.toggleState = isOn
            if let base = item.toggleBase {
                (item.title, item.symbol) = PaletteTunables.toggleStyle.value.apply(title: base.title, symbol: base.symbol, isOn: isOn)
            }
            return item
        }
    }
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

    /// A provider whose source can say that more is to come (a list its owner has not finished building): it
    /// shows each read's list and reads again by itself after `wait` returns, until a read is complete or the
    /// page that reads it goes away. `items()` is one read, so a headless caller never waits for the rest.
    ///
    /// - Parameters:
    ///   - read: One read: its rows, and whether more is to come. Nil ends the reads (the source is gone).
    ///   - wait: Suspends before the read that follows `reads` reads (a clock sleep that backs off); it throws when cancelled.
    public static func rereading(id: String, showsItemsForEmptyQuery: Bool = true,
                                 read: @escaping @MainActor () async -> (items: [PaletteItem], moreToCome: Bool)?,
                                 wait: @escaping @MainActor (_ reads: Int) async throws -> Void) -> AsyncPaletteProvider {
        AsyncPaletteProvider(id: id, showsItemsForEmptyQuery: showsItemsForEmptyQuery, once: { await read()?.items ?? [] }, updates: {
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
            // task-owner: one open's reads of a list that is not complete; ends at a complete read or with the stream's consumer
            // main-hop-allow: not an action's work: it awaits a read and then a clock wait, which no frame queue can; on the main actor it only passes one read's rows on, one time per wait
            let task = Task { @MainActor in
                var reads = 0
                // wakeup-allow: each pass awaits one read and then `wait` (History: a Backoff sleep of 1 s to 8 s, because the daemon sends no event when a list becomes complete); a complete read, a source that is gone or the consumer's cancel ends it, so it runs only while the person has the list open
                while !Task.isCancelled, let list = await read() {
                    reads += 1
                    continuation.yield(list.items)
                    guard list.moreToCome else { break }
                    do { try await wait(reads) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        })
    }

    private init(id: String, showsItemsForEmptyQuery: Bool, once load: @escaping @MainActor () async -> [PaletteItem],
                 updates: @escaping @MainActor () -> AsyncStream<[PaletteItem]>) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        immediateItems = nil
        self.load = load
        self.updates = updates
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
