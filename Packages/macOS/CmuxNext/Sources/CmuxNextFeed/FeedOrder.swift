public import Foundation

/// Sort orders and filters shared by the variants (pure).
public nonisolated enum FeedOrder {
    /// Requests: higher priority first, then newest.
    public static func attention(_ a: FeedItem, _ b: FeedItem) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        return newest(a, b)
    }

    /// Newest first; ids break ties so the order is total.
    public static func newest(_ a: FeedItem, _ b: FeedItem) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }

    /// `items` in ``newest(_:_:)`` order. Sorts small keys and gathers once: a feed item is a large
    /// value, and moving 1,500 of them through a sort cost a live Feed about 10 ms per event.
    // perf-hot: 2ms feed-live-event
    public static func sortedNewest<S: Sequence>(_ items: S) -> [FeedItem] where S.Element == FeedItem {
        let items = Array(items)
        let keys = items.map { (date: $0.createdAt, id: $0.id) }
        let order = keys.indices.sorted { a, b in
            keys[a].date != keys[b].date ? keys[a].date > keys[b].date : keys[a].id < keys[b].id
        }
        return order.map { items[$0] }
    }
}

/// The badge (feed.md 3.7): open requests plus unread notices.
public nonisolated struct FeedCounts: Sendable, Equatable {
    public var openRequests: Int
    public var unreadNotices: Int

    public init(items: [FeedItem], now: Date) {
        let active = items.filter { $0.isActive(at: now) }
        openRequests = active.filter(\.isOpenRequest).count
        unreadNotices = active.filter { !$0.isRequest && $0.isUnread }.count
    }

    public init(openRequests: Int, unreadNotices: Int) {
        self.openRequests = openRequests
        self.unreadNotices = unreadNotices
    }

    public var badge: Int { openRequests + unreadNotices }
}
