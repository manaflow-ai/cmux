public import Foundation

/// Variant `list`: open requests pinned on top, everything else below,
/// newest first. Archived and snoozed items are out.
public nonisolated struct FeedListSections: Sendable, Equatable {
    public var requests: [FeedItem] = []
    public var rest: [FeedItem] = []

    public init(items: [FeedItem], now: Date) {
        for item in items where item.isActive(at: now) {
            if item.isOpenRequest { requests.append(item) } else { rest.append(item) }
        }
        requests.sort(by: FeedOrder.attention)
        rest.sort(by: FeedOrder.newest)
    }

    public var isEmpty: Bool { requests.isEmpty && rest.isEmpty }
}

/// Variant `inbox`: every active item lands in exactly one group. "Needs
/// you" holds the open requests, one row each (each needs its own answer).
/// "Today" and "Earlier" split the rest by the calendar day of `now`, and
/// items of one thread collapse into one entry headed by the newest.
public nonisolated struct FeedInboxGroups: Sendable, Equatable {
    public var needsYou: [FeedInboxEntry] = []
    public var today: [FeedInboxEntry] = []
    public var earlier: [FeedInboxEntry] = []

    public init(items: [FeedItem], now: Date, calendar: Calendar = .current) {
        let sections = FeedListSections(items: items, now: now)
        needsYou = sections.requests.map { FeedInboxEntry(head: $0, members: [$0]) }
        var todayItems: [FeedItem] = []
        var earlierItems: [FeedItem] = []
        for item in sections.rest {
            if calendar.isDate(item.createdAt, inSameDayAs: now) { todayItems.append(item) } else { earlierItems.append(item) }
        }
        today = Self.threads(todayItems)
        earlier = Self.threads(earlierItems)
    }

    /// Collapses items that share a thread; `items` are newest first, so
    /// each entry's head is its newest item and entries stay newest first.
    static func threads(_ items: [FeedItem]) -> [FeedInboxEntry] {
        var entries: [FeedInboxEntry] = []
        var index: [String: Int] = [:]
        for item in items {
            guard let thread = item.thread else {
                entries.append(FeedInboxEntry(head: item, members: [item]))
                continue
            }
            if let at = index[thread] {
                entries[at].members.append(item)
            } else {
                index[thread] = entries.count
                entries.append(FeedInboxEntry(head: item, members: [item]))
            }
        }
        return entries
    }

    public var all: [FeedInboxEntry] { needsYou + today + earlier }
    public var first: FeedInboxEntry? { all.first }
}

/// One inbox row: an item, or a collapsed thread headed by its newest item.
public nonisolated struct FeedInboxEntry: Sendable, Equatable, Identifiable {
    public var head: FeedItem
    /// Newest first; the head is the first member.
    public var members: [FeedItem]

    public var id: String { head.thread.map { "thread:" + $0 } ?? head.id }
    public var isThread: Bool { members.count > 1 }
    public var unread: Int { members.filter(\.isUnread).count }
}
