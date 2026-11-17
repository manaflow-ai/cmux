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

/// The paging edge's state (the bottom of a `.down` list, the top of an `.up` one).
public enum PagedListEdge: Equatable, Sendable {
    /// More pages exist; the next is read as the reader nears the edge.
    case more
    case loading
    /// The last page read failed; the edge offers Try Again.
    case failed(String)
    /// The oldest item is shown.
    case end
}

/// A paged source's state for a ``PagedList``: items in the order they show, the first
/// page's phase and the edge's. One owner reads pages (`loader`), drops answers that a
/// newer first-page read replaced, and never reads two pages at once. Screens with their
/// own model (one that also filters, archives…) can drive ``PagedList`` directly instead.
@MainActor
@Observable
public final class PagedListModel<Item: Identifiable & Equatable & Sendable> where Item.ID: Sendable {
    public typealias Loader = @MainActor (_ cursor: String?) async throws -> PagedListPage<Item>

    public let direction: PagedListDirection
    public private(set) var phase: PagedListPhase = .loading
    public private(set) var edge: PagedListEdge = .more
    /// Newest first (load order).
    public private(set) var newestFirst: [Item] = []
    /// A first-page read runs over rows already shown (refresh).
    public private(set) var refreshing = false

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loader: Loader
    @ObservationIgnored private var loadingFirst = false
    /// The text a failure shows.
    @ObservationIgnored public var message: (any Error) -> String = { _ in String(localized: "Check your connection and try again.") }

    public init(direction: PagedListDirection, loader: @escaping Loader) {
        self.direction = direction
        self.loader = loader
    }

    /// The items in the order they show, top to bottom.
    public var items: [Item] { direction == .down ? newestFirst : newestFirst.reversed() }

    /// Reads the first page (again: the rows shown stay until it lands).
    public func loadFirst() async {
        generation &+= 1
        let run = generation
        loadingFirst = true
        if newestFirst.isEmpty { phase = .loading } else { refreshing = true }
        defer {
            if run == generation {
                loadingFirst = false
                refreshing = false
            }
        }
        do {
            let page = try await loader(nil)
            guard run == generation else { return }
            newestFirst = Self.unique(page.items)
            cursor = page.nextCursor
            edge = page.nextCursor == nil ? .end : .more
            phase = .loaded
        } catch {
            guard run == generation else { return }
            if newestFirst.isEmpty { phase = .failed(message(error)) }
        }
    }

    /// Reads the next (older) page; does nothing while one is read, at the end, or before
    /// the first page.
    public func loadMore() async {
        guard phase == .loaded, !loadingFirst, edge == .more || isFailedEdge, let cursor else { return }
        let run = generation
        edge = .loading
        do {
            let page = try await loader(cursor)
            guard run == generation else { return }
            let known = Set(newestFirst.map(\.id))
            newestFirst += page.items.filter { !known.contains($0.id) }
            self.cursor = page.nextCursor
            edge = page.nextCursor == nil ? .end : .more
        } catch {
            guard run == generation else { return }
            edge = .failed(message(error))
        }
    }

    /// Try Again on whichever read failed.
    public func retry() async {
        if case .failed = phase { await loadFirst() } else if isFailedEdge { await loadMore() }
    }

    /// Items that arrived live at the newest end (a new message, a new chat).
    public func receiveNewest(_ items: [Item]) {
        let fresh = Self.unique(items)
        let ids = Set(fresh.map(\.id))
        newestFirst = fresh + newestFirst.filter { !ids.contains($0.id) }
        if phase != .loaded, !fresh.isEmpty { phase = .loaded }
    }

    /// An item's new value, in place.
    public func update(_ item: Item) {
        guard let index = newestFirst.firstIndex(where: { $0.id == item.id }) else { return }
        newestFirst[index] = item
    }

    public func remove(_ id: Item.ID) {
        newestFirst.removeAll { $0.id == id }
    }

    private var isFailedEdge: Bool {
        if case .failed = edge { return true }
        return false
    }

    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
