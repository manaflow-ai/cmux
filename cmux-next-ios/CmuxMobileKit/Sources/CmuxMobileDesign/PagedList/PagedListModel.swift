import Foundation
import Observation

/// Which way a ``PagedList`` grows (verify/paged-list.md).
public enum PagedListDirection: String, Sendable, Hashable, CaseIterable {
    /// Newest first, at the top, where the list opens; older pages join at the bottom
    /// as the reader scrolls down (the Feed, chat lists, the workspaces list).
    case down
    /// Newest last, at the bottom, where the list opens; older pages join at the top
    /// as the reader scrolls up (a chat's history). What the reader sees never moves
    /// when a page lands above it.
    case up
}

/// One page as a source answers it: items newest first, and where the next (older)
/// page starts, nil when this was the oldest.
public struct PagedListPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// The first page's state: what the whole list shows before it has rows.
public enum PagedListPhase: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// A paging edge's state: the older edge (the bottom of a `.down` list, the top of an `.up` one) or
/// the newer edge of a model that keeps only a window in memory.
public enum PagedListEdge: Equatable, Sendable {
    /// More rows exist; they are read as the reader nears the edge.
    case more
    case loading
    /// The last read failed; the edge offers Try Again.
    case failed(String)
    /// The last row is shown.
    case end
}

/// How many rows a ``PagedListModel`` keeps in memory (verify/paged-list.md, "Memory").
public struct PagedListMemory: Sendable, Equatable {
    /// Rows kept in memory and in the list around the reader; nil keeps every row.
    public var window: Int?

    /// Every row stays in memory (short lists).
    public static let unbounded = PagedListMemory(window: nil)

    /// About `rows` rows around the reader stay in memory and in the list; the rest wait in a file
    /// on disk (``PagedListSpillBudget``, 1 GB for every list together) and come back, in a few
    /// milliseconds, as the reader nears them. At least 120.
    public static func window(_ rows: Int) -> PagedListMemory { PagedListMemory(window: max(120, rows)) }
}

/// A paged source's state for a ``PagedList``: rows in the order they show, the first page's phase
/// and both edges. One owner reads pages: one read in flight per edge, a refresh that drops the
/// answers it replaced, a second refresh that waits for the first, a source that repeats a cursor
/// or keeps answering empty pages stopped (verify/paged-list.md, "Paging guards").
///
/// The order lives in a linked list over ids (``PagedListOrder``), so a change costs O(1) wherever
/// it lands. With ``PagedListMemory/window(_:)`` only the rows around the reader are values in
/// memory; the rest are ids here and values on disk. Screens with their own model can drive
/// ``PagedList`` directly instead.
@MainActor
@Observable
public final class PagedListModel<Item: Identifiable & Equatable & Sendable> where Item.ID: Sendable {
    public typealias Loader = @MainActor (_ cursor: String?) async throws -> PagedListPage<Item>

    public let direction: PagedListDirection
    public private(set) var phase: PagedListPhase = .loading
    /// The older edge.
    public private(set) var edge: PagedListEdge = .more
    /// The newer edge: `.end` while the newest rows are in the list; `.more` or `.loading` while a
    /// windowed model holds them on disk because the reader is deep in the list.
    public private(set) var newerEdge: PagedListEdge = .end
    /// The rows in the list, newest first (the window, when memory is bounded).
    public private(set) var newestFirst: [Item] = []
    /// A first-page read runs over rows already shown (refresh).
    public private(set) var refreshing = false
    /// Why the last refresh failed while rows were showing (nil after one succeeds); the screen
    /// shows it, as the rows it keeps are older than the reader asked for.
    public private(set) var refreshFailure: String?
    /// Every row the model knows, in memory or on disk.
    public private(set) var total = 0
    /// Rows that arrived at the newest end while it was out of the window (a screen's "N new").
    public private(set) var unseenNewest = 0

    /// The rows in the order they show, top to bottom.
    public var items: [Item] { direction == .down ? newestFirst : newestFirst.reversed() }

    // MARK: State

    @ObservationIgnored private var order = PagedListOrder<Item.ID>()
    /// Row values in memory: every row when unbounded, else the window's (and changes not yet
    /// written to disk).
    @ObservationIgnored private var values: [Item.ID: Item] = [:]
    /// Values in memory the disk doesn't have yet.
    @ObservationIgnored private var dirty: Set<Item.ID> = []
    @ObservationIgnored private let windowSize: Int?
    /// The window's newest row (nil: the head).
    @ObservationIgnored private var windowStart: Item.ID?
    @ObservationIgnored private var windowIDs: [Item.ID] = []
    /// The row being read (the list reports it), which the window keeps in its middle half.
    @ObservationIgnored private var reader: Item.ID?
    @ObservationIgnored private var reads: Set<Item.ID> = []
    /// Disk reads belong to this generation: a list read again from its first page drops older answers.
    @ObservationIgnored private var readGeneration = 0
    /// Rows that changed while their disk read ran: that read's value is older than the change, so
    /// it is dropped and the row read again.
    @ObservationIgnored private var staleReads: Set<Item.ID> = []
    @ObservationIgnored private let spill: Spill?

    @ObservationIgnored private var loader: Loader
    @ObservationIgnored private var changeStream: (() -> AsyncStream<[PagedListChange<Item>]>)?
    /// The older edge as the source has it (``edge`` adds the window's own).
    @ObservationIgnored private var sourceEdge: PagedListEdge = .more
    @ObservationIgnored private var cursor: String?
    /// Cursors read since the first page: a source that answers one again would loop.
    @ObservationIgnored private var usedCursors: Set<String> = []
    @ObservationIgnored private var emptyPages = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var firstRead: Task<Void, Never>?
    /// Changes received since the last flush; applied together once per run loop turn, so a flood
    /// of changes costs one list update (one frame), not one per change.
    @ObservationIgnored private var pending: [PagedListChange<Item>] = []
    @ObservationIgnored private var flushQueued = false
    /// Changes applied (the lab and the stress bench count them).
    @ObservationIgnored public private(set) var changesApplied = 0
    /// List updates the changes cost (one per flush).
    @ObservationIgnored public private(set) var flushes = 0
    /// Pages a source answered with a cursor it had already given, or a run of empty pages, that
    /// the model stopped at (tests).
    @ObservationIgnored public private(set) var stoppedLoops = 0
    /// Rows the disk could not give back (a failed read, a damaged record): dropped from the list
    /// once, never asked for again (tests).
    @ObservationIgnored public private(set) var lostRows = 0
    /// The text a failure shows.
    @ObservationIgnored public var message: (any Error) -> String = { _ in String(localized: "Check your connection and try again.") }

    /// At most this many empty pages in a row before the older edge ends.
    static var emptyPageLimit: Int { 8 }

    /// The disk side of a windowed model (type-erased: only `Codable` rows spill).
    private struct Spill {
        var write: ([Item]) -> Void
        var read: ([Item.ID], @escaping @MainActor @Sendable ([Item.ID: Item]) -> Void) -> Void
        var remove: ([Item.ID]) -> Void
        var removeAll: () -> Void
        var stats: (@escaping @MainActor @Sendable (Int, Int, Int) -> Void) -> Void
    }

    public init(direction: PagedListDirection, loader: @escaping Loader) {
        self.direction = direction
        self.loader = loader
        windowSize = nil
        spill = nil
    }

    private init(direction: PagedListDirection, window: Int?, spill: Spill?, loader: @escaping Loader) {
        self.direction = direction
        self.loader = loader
        windowSize = window
        self.spill = spill
    }

    /// Reads `source`'s pages and, once ``listen()`` runs, its changes.
    public convenience init<Source: PagedListSource>(direction: PagedListDirection, source: Source) where Source.Item == Item {
        self.init(direction: direction) { [weak source] cursor in
            guard let source else { throw CancellationError() }
            return try await source.page(after: cursor)
        }
        changeStream = { [weak source] in source?.changes() ?? AsyncStream { $0.finish() } }
    }

    /// Applies the source's changes until the stream ends or the caller's task is cancelled (call
    /// it from the screen's `.task`).
    public func listen() async {
        guard let changeStream else { return }
        for await batch in changeStream() {
            receive(batch)
        }
    }

    /// The disk side's counts (the lab and the bench): rows on disk, rows the disk couldn't take
    /// (kept in memory), the file's size. Nothing for an unbounded model.
    public func spillStats(_ done: @escaping @MainActor @Sendable (_ onDisk: Int, _ inMemory: Int, _ fileBytes: Int) -> Void) {
        spill?.stats(done)
    }

    /// Row values in memory now (the bench's memory bound).
    public var valuesInMemory: Int { values.count }

    // MARK: Reading pages

    /// Reads the first page (again: the rows shown stay until it lands). A refresh asked for while
    /// one runs waits for it instead of reading twice.
    public func loadFirst() async {
        if let firstRead {
            await firstRead.value
            return
        }
        let read = Task { await self.readFirst() }
        firstRead = read
        await read.value
        firstRead = nil
    }

    private func readFirst() async {
        generation &+= 1
        let run = generation
        if order.isEmpty { phase = .loading } else { refreshing = true }
        defer { if run == generation { refreshing = false } }
        do {
            let page = try await loader(nil)
            guard run == generation else { return }
            let fresh = Self.unique(page.items)
            if page.nextCursor != nil, let last = fresh.last, order.contains(last.id), order.after(last.id) != nil {
                // The older rows already read stay (and so does the reader in them); their cursor
                // still reads what comes after them.
                mergeHead(fresh, through: last.id)
                if sourceEdge == .loading { sourceEdge = cursor == nil ? .end : .more }
            } else {
                replaceAll(fresh)
                cursor = page.nextCursor
                usedCursors = []
                emptyPages = 0
                sourceEdge = page.nextCursor == nil ? .end : .more
            }
            phase = .loaded
            refreshFailure = nil
            rebuild()
        } catch {
            guard run == generation else { return }
            if order.isEmpty {
                phase = .failed(message(error))
            } else {
                // The rows stay. A page read this refresh superseded left the edge spinning: it
                // can read again.
                refreshFailure = message(error)
                if sourceEdge == .loading { sourceEdge = cursor == nil ? .end : .more }
                rebuild()
            }
        }
    }

    /// Reads the next (older) rows: from disk when the window's older end is not the list's, else
    /// the source's next page. Does nothing while a read runs, at the end, or before the first page.
    public func loadMore() async {
        if windowSize != nil, let last = windowIDs.last, last != order.tail {
            moveWindow(older: true, end: last)
            return
        }
        guard phase == .loaded, firstRead == nil, sourceEdge == .more || isFailed(sourceEdge), let cursor else { return }
        let run = generation
        sourceEdge = .loading
        usedCursors.insert(cursor)
        rebuild()
        do {
            let page = try await loader(cursor)
            guard run == generation else { return }
            let fresh = Self.unique(page.items).filter { !order.contains($0.id) }
            for item in fresh {
                order.append(item.id)
                store(item)
            }
            emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
            if let next = page.nextCursor, usedCursors.contains(next) || emptyPages >= Self.emptyPageLimit {
                // A cursor it already gave (or page after empty page) would read forever.
                stoppedLoops += 1
                self.cursor = nil
                sourceEdge = .end
            } else {
                self.cursor = page.nextCursor
                sourceEdge = page.nextCursor == nil ? .end : .more
            }
            rebuild()
        } catch {
            guard run == generation else { return }
            sourceEdge = .failed(message(error))
            rebuild()
        }
    }

    /// Reads the newer rows a windowed model holds on disk (the reader neared the newer edge).
    public func loadNewer() {
        guard windowSize != nil, let first = windowIDs.first, first != order.head else { return }
        moveWindow(older: false, end: first)
    }

    /// Moves a windowed model's window toward the rows on disk past `end`, its older or newer end,
    /// around the row being read (`end` when the list hasn't reported one): that row ends a quarter
    /// window from the side the window leaves. So the window never passes the reader, and asking
    /// again, before or after the rows are back, moves nothing. One move at a time: none while a
    /// disk read runs.
    private func moveWindow(older: Bool, end: Item.ID) {
        guard let size = windowSize, reads.isEmpty else { return }
        let target = reader.flatMap { windowIDs.contains($0) ? $0 : nil } ?? end
        guard let at = windowIDs.firstIndex(of: target) else { return }
        if older {
            // Already a quarter window or less from the newer side: the window can't go further.
            guard at > size / 4 else { return }
        } else {
            guard at < size * 3 / 4 else { return }
        }
        let start = order.walkBack(from: target, steps: older ? size / 4 : size * 3 / 4)
        windowStart = start == order.head ? nil : start
        reader = target
        rebuild()
    }

    /// Try Again on whichever read failed.
    public func retry() async {
        if case .failed = phase { await loadFirst() } else if isFailed(sourceEdge) { await loadMore() }
    }

    /// The row being read (the list reports it as the reader scrolls): a windowed model keeps it in
    /// the middle half of its window, reading rows back from disk ahead of the reader.
    public func reading(_ id: Item.ID?) {
        guard windowSize != nil, id != reader else { return }
        reader = id
        guard let id, let size = windowSize, let at = windowIDs.firstIndex(of: id) else { return }
        let nearNewer = at < size / 4 && windowIDs.first != order.head
        let nearOlder = at > size * 3 / 4 && windowIDs.last != order.tail
        if nearNewer || nearOlder { rebuild() }
    }

    /// The reader asked for the newest rows (a "N new" pill, a jump): the window goes to the head.
    public func showNewest() {
        unseenNewest = 0
        guard windowSize != nil else { return }
        reader = nil
        windowStart = nil
        rebuild()
    }

    // MARK: Live changes

    /// Changes from a live source; coalesced and applied once per run loop turn.
    public func receive(_ changes: [PagedListChange<Item>]) {
        pending += changes
        guard !flushQueued else { return }
        flushQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushQueued = false
        let changes = pending
        pending = []
        guard !changes.isEmpty else { return }
        apply(changes)
        changesApplied += changes.count
        flushes += 1
    }

    /// Items that arrived live at the newest end (a new message, a new chat).
    public func receiveNewest(_ items: [Item]) { apply([.newest(items)]) }

    /// An item's new value, in place.
    public func update(_ item: Item) { apply([.update([item])]) }

    public func remove(_ id: Item.ID) { apply([.remove([id])]) }

    private func apply(_ changes: [PagedListChange<Item>]) {
        var removed: [Item.ID] = []
        for change in changes {
            switch change {
            case .newest(let items):
                let away = windowSize != nil && windowIDs.first != nil && windowIDs.first != order.head
                for item in Self.unique(items).reversed() {
                    if away, !order.contains(item.id) { unseenNewest += 1 }
                    order.insertAtHead(item.id)
                    store(item)
                }
            case .insert(let items, let after):
                // An anchor the model hasn't read: the rows show when their page is read.
                guard order.contains(after) else { continue }
                var anchor = after
                for item in Self.unique(items) where item.id != anchor {
                    order.insert(item.id, after: anchor)
                    store(item)
                    anchor = item.id
                }
            case .update(let items):
                for item in items where order.contains(item.id) { store(item) }
            case .remove(let ids):
                for id in ids where order.contains(id) {
                    order.remove(id)
                    values[id] = nil
                    dirty.remove(id)
                    removed.append(id)
                }
            case .move(let id, let after):
                guard order.contains(id) else { continue }
                if let after { order.insert(id, after: after) } else { order.insertAtHead(id) }
            }
        }
        spill?.remove(removed)
        if phase != .loaded, !order.isEmpty { phase = .loaded }
        rebuild()
    }

    // MARK: The window

    private func store(_ item: Item) {
        values[item.id] = item
        if spill != nil { dirty.insert(item.id) }
        if reads.contains(item.id) { staleReads.insert(item.id) }
    }

    private func replaceAll(_ fresh: [Item]) {
        order = PagedListOrder()
        values.removeAll(keepingCapacity: true)
        dirty.removeAll()
        reads.removeAll()
        staleReads.removeAll()
        readGeneration += 1
        spill?.removeAll()
        windowStart = nil
        reader = nil
        unseenNewest = 0
        for item in fresh {
            order.append(item.id)
            store(item)
        }
    }

    /// `fresh`, a first page read again, takes the place of the rows from the head through `last`.
    private func mergeHead(_ fresh: [Item], through last: Item.ID) {
        let keep = Set(fresh.map(\.id))
        var gone: [Item.ID] = []
        var cursor = order.head
        while let id = cursor {
            cursor = order.after(id)
            if !keep.contains(id) { gone.append(id) }
            if id == last { break }
        }
        for id in gone {
            order.remove(id)
            values[id] = nil
            dirty.remove(id)
        }
        spill?.remove(gone)
        for item in fresh.reversed() {
            order.insertAtHead(item.id)
            if values[item.id] != item { store(item) }
        }
    }

    /// Recomputes the window around the reader, sends what left it to disk, reads back what entered
    /// it, and publishes the rows in memory and both edges. O(window) per call.
    private func rebuild() {
        total = order.count
        guard let size = windowSize else {
            newestFirst = order.all().compactMap { values[$0] }
            edge = sourceEdge
            newerEdge = .end
            return
        }
        if let start = windowStart, !order.contains(start) { windowStart = nil }
        var ids = order.ids(from: windowStart ?? order.head, count: size)
        if let reader, order.contains(reader) {
            let at = ids.firstIndex(of: reader)
            let atHead = ids.first == order.head
            let atTail = ids.last == order.tail
            let misplaced = at.map { ($0 < size / 4 && !atHead) || ($0 > size * 3 / 4 && !atTail) } ?? true
            if misplaced {
                let start = order.walkBack(from: reader, steps: size / 2)
                windowStart = start == order.head ? nil : start
                ids = order.ids(from: windowStart ?? order.head, count: size)
            }
        }
        windowIDs = ids
        let inWindow = Set(ids)

        // Out of the window: to disk (only what the disk doesn't have), and out of memory.
        var leaving: [Item] = []
        for (id, value) in values where !inWindow.contains(id) {
            if dirty.contains(id) { leaving.append(value) }
        }
        if !leaving.isEmpty { spill?.write(leaving) }
        values = values.filter { inWindow.contains($0.key) }
        dirty.formIntersection(inWindow)

        // Into the window from disk.
        let missing = ids.filter { values[$0] == nil && !reads.contains($0) }
        if !missing.isEmpty {
            reads.formUnion(missing)
            let run = readGeneration
            spill?.read(missing) { [weak self] found in
                guard let self, run == self.readGeneration else { return }
                self.landRead(missing, found)
            }
        }

        // The rows shown: the run of rows in memory around the reader (a row still on its way from
        // disk ends it, and that side's edge spins).
        let center = reader.flatMap { ids.firstIndex(of: $0) } ?? 0
        var low = min(center, max(0, ids.count - 1))
        var high = low
        if ids.isEmpty || values[ids[low]] == nil {
            low = 0
            high = -1
            if let first = ids.firstIndex(where: { values[$0] != nil }) {
                low = first
                high = first
            }
        }
        if high >= low {
            while low > 0, values[ids[low - 1]] != nil { low -= 1 }
            while high + 1 < ids.count, values[ids[high + 1]] != nil { high += 1 }
            newestFirst = ids[low...high].compactMap { values[$0] }
        } else {
            newestFirst = []
        }
        let headShown = high >= low && low == 0 && ids.first == order.head
        let tailShown = high >= low && high == ids.count - 1 && ids.last == order.tail
        newerEdge = headShown || order.isEmpty ? .end : (reads.isEmpty ? .more : .loading)
        edge = tailShown || order.isEmpty ? sourceEdge : (reads.isEmpty ? .more : .loading)
        if headShown { unseenNewest = 0 }
    }

    /// A disk read's answer: the rows still wanted take their values; a row changed while the read
    /// ran is read again (its change is newer); a row the disk didn't have is dropped, so it is not
    /// asked for forever.
    private func landRead(_ asked: [Item.ID], _ found: [Item.ID: Item]) {
        reads.subtract(asked)
        let wanted = Set(windowIDs)
        var lost: [Item.ID] = []
        for id in asked {
            if staleReads.remove(id) != nil { continue }
            guard values[id] == nil, order.contains(id) else { continue }
            if let value = found[id] {
                if wanted.contains(id) { values[id] = value }
            } else {
                lost.append(id)
            }
        }
        if !lost.isEmpty {
            for id in lost {
                order.remove(id)
                dirty.remove(id)
            }
            spill?.remove(lost)
            lostRows += lost.count
        }
        rebuild()
    }

    private func isFailed(_ edge: PagedListEdge) -> Bool {
        if case .failed = edge { return true }
        return false
    }

    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

extension PagedListModel where Item: Codable {
    /// A model that keeps about `memory`'s window of rows in memory and the rest on disk.
    public convenience init(direction: PagedListDirection, memory: PagedListMemory, loader: @escaping Loader) {
        let spill = memory.window == nil ? nil : PagedListSpill<Item>()
        self.init(direction: direction, window: memory.window, spill: spill.map { spill in
            Spill(write: { spill.write($0) }, read: { spill.read($0, done: $1) }, remove: { spill.remove($0) },
                  removeAll: { spill.removeAll() }, stats: { spill.stats($0) })
        }, loader: loader)
    }

    /// Reads `source` with a bounded window (``PagedListMemory``).
    public convenience init<Source: PagedListSource>(direction: PagedListDirection, source: Source, memory: PagedListMemory) where Source.Item == Item {
        self.init(direction: direction, memory: memory) { [weak source] cursor in
            guard let source else { throw CancellationError() }
            return try await source.page(after: cursor)
        }
        changeStream = { [weak source] in source?.changes() ?? AsyncStream { $0.finish() } }
    }
}

extension Array where Element: Identifiable {
    /// This list (newest first) with `fresh`, a first page read again, in place of its head: the
    /// rows after the page's last row stay, so a reader in the older pages keeps them. Nil when the
    /// page doesn't reach a row this list has (more new rows than a page: the rest is unknown) or is
    /// the whole list (`hasMore` false).
    public func mergingFirstPage(_ fresh: [Element], hasMore: Bool) -> [Element]? {
        guard hasMore, let last = fresh.last, let at = firstIndex(where: { $0.id == last.id }), at + 1 < count else { return nil }
        let ids = Set(fresh.map(\.id))
        return fresh + self[(at + 1)...].filter { !ids.contains($0.id) }
    }
}
