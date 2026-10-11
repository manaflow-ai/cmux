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

    /// Variant `compact` (menu bar): open requests only.
    public static func menubar(_ items: [FeedItem], now: Date) -> [FeedItem] {
        items.filter { $0.isOpenRequest && $0.isActive(at: now) }.sorted(by: attention)
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

    public var badge: Int { openRequests + unreadNotices }
}
