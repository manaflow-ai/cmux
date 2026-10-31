import Foundation

/// The one owner of the feed as the person sees it: each item with this client's pending intents
/// applied, the panel list's order (open requests by attention, then everything else newest
/// first), every item newest first, and the badge counts. ``FeedModel`` tells it which ids an
/// event or intent touched; it recomputes those ids only and reports how the list moved. Nothing
/// here sorts, filters or compares the whole feed per change.
nonisolated struct FeedLedger: Sendable {
    /// Mirror + pending intents, by id.
    private(set) var visible: [String: FeedItem] = [:]
    /// Bumps each time an item's visible value (or its pending state) changes: rows cache by it.
    private(set) var stamps: [String: Int] = [:]
    /// The panel list: active items (not archived, not snoozed).
    private(set) var list = FeedOrderedIndex<String, FeedListKey>()
    /// Every visible item, newest first.
    private(set) var timeline = FeedOrderedIndex<String, FeedTimeKey>()
    private(set) var openRequests = 0
    private(set) var unreadNotices = 0
    /// Unread visible items, active or not (Mark All Read).
    private(set) var unread = 0
    /// Items hidden by a snooze, until when: they come back when `now` passes it.
    private var snoozed: [String: Date] = [:]
    private var stamp = 0

    var counts: FeedCounts { FeedCounts(openRequests: openRequests, unreadNotices: unreadNotices) }

    /// Snoozed items whose time has come by `now`.
    func woken(at now: Date) -> [String] {
        snoozed.compactMap { $0.value <= now ? $0.key : nil }
    }

    /// Recomputes `ids` from the mirror and the intents. `forced` ids report a changed row even
    /// when their value did not change (an intent on them started or settled). Returns the
    /// panel list's edits, and whether any item changed at all (an archived one moves no row).
    mutating func update<S: Sequence>(
        _ ids: S, confirmed: [String: FeedItem], pending: [FeedIntent],
        user: String, device: String, now: Date, forced: Set<String> = []
    ) -> (list: FeedRowChanges, changed: Bool) where S.Element == String {
        var listBatch: [String: FeedListKey?] = [:]
        var timeBatch: [String: FeedTimeKey?] = [:]
        var changed = Set<String>()
        for id in ids {
            let old = visible[id]
            let new = Self.overlay(id, confirmed: confirmed, pending: pending, user: user, device: device)
            let wasActive = list.contains(id)
            let isActive = new?.isActive(at: now) ?? false
            guard old != new || wasActive != isActive || forced.contains(id) else { continue }
            if let old { count(old, active: wasActive, sign: -1) }
            if let new { count(new, active: isActive, sign: 1) }
            visible[id] = new
            stamp &+= 1
            stamps[id] = new == nil ? nil : stamp
            changed.insert(id)
            // updateValue, not the subscript: assigning nil through `[ID: Key?]`'s subscript can drop
            // the entry instead of storing "no longer a member".
            let listKey: FeedListKey? = isActive ? new.map(FeedListKey.init) : nil
            listBatch.updateValue(listKey, forKey: id)
            timeBatch.updateValue(new.map(FeedTimeKey.init), forKey: id)
            if let new, !new.isArchived, let until = new.snoozedUntil, until > now {
                snoozed[id] = until
            } else {
                snoozed[id] = nil
            }
        }
        guard !changed.isEmpty else { return (FeedRowChanges(), false) }
        _ = timeline.apply(timeBatch, changed: changed)
        return (list.apply(listBatch, changed: changed), true)
    }

    private mutating func count(_ item: FeedItem, active: Bool, sign: Int) {
        if item.isUnread { unread += sign }
        guard active else { return }
        if item.isOpenRequest { openRequests += sign }
        if !item.isRequest && item.isUnread { unreadNotices += sign }
    }

    /// One item with this client's pending intents applied, in send order.
    static func overlay(_ id: String, confirmed: [String: FeedItem], pending: [FeedIntent],
                        user: String, device: String) -> FeedItem? {
        guard let item = confirmed[id] else { return nil }
        var items = [id: item]
        for intent in pending where intent.items?.contains(id) ?? true {
            intent.apply(to: &items, user: user, device: device)
        }
        return items[id]
    }
}

/// The panel list's order: open requests first, by priority then newest; then everything else,
/// newest first; ids break ties (``FeedOrder/attention(_:_:)`` and ``FeedOrder/newest(_:_:)``).
nonisolated struct FeedListKey: Comparable, Sendable {
    var section: Int
    var rank: Int
    var time: Date
    var id: String

    init(_ item: FeedItem) {
        section = item.isOpenRequest ? 0 : 1
        rank = item.isOpenRequest ? -item.priority.rank : 0
        time = item.createdAt
        id = item.id
    }

    var isRequest: Bool { section == 0 }

    static func < (a: Self, b: Self) -> Bool {
        if a.section != b.section { return a.section < b.section }
        if a.rank != b.rank { return a.rank < b.rank }
        if a.time != b.time { return a.time > b.time }
        return a.id < b.id
    }
}

/// Newest first; ids break ties.
nonisolated struct FeedTimeKey: Comparable, Sendable {
    var time: Date
    var id: String

    init(_ item: FeedItem) {
        time = item.createdAt
        id = item.id
    }

    static func < (a: Self, b: Self) -> Bool {
        a.time != b.time ? a.time > b.time : a.id < b.id
    }
}
