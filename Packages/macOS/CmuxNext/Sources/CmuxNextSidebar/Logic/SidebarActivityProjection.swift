public import Foundation

/// The day group a chat's latest activity falls in, in the order shown.
public nonisolated enum SidebarActivityBucket: Hashable, Sendable, CaseIterable {
    case today
    case yesterday
    /// The five days before yesterday: with today and yesterday, the last seven days.
    case thisWeek
    case older

    /// The group of a chat last active at `date`, by `calendar` days. A time
    /// after `now` (clock skew between machines) counts as today.
    public static func of(_ date: Date, now: Date, calendar: Calendar) -> Self {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let weekStart = calendar.date(byAdding: .day, value: -6, to: today) else { return .older }
        if date >= yesterday { return .yesterday }
        return date >= weekStart ? .thisWeek : .older
    }
}

/// The Activity view's content: Priority, then every chat by day. Pure.
public nonisolated struct SidebarActivityProjection: Hashable, Sendable {
    public struct Group: Hashable, Sendable {
        public var bucket: SidebarActivityBucket
        /// Newest first.
        public var chats: [SidebarActivityChat]
    }

    /// The chats with attention, most urgent first, then newest first.
    public var priority: [SidebarActivityChat]
    /// Every chat (Priority ones too), in day order; empty days are left out.
    public var groups: [Group]

    public init(chats: [SidebarActivityChat], now: Date, calendar: Calendar) {
        let newestFirst = chats.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        // A stable sort by urgency keeps newest first within each kind.
        priority = SidebarActivityAttention.allCases.flatMap { kind in newestFirst.filter { $0.attention == kind } }
        let byBucket = Dictionary(grouping: newestFirst) { SidebarActivityBucket.of($0.updatedAt, now: now, calendar: calendar) }
        groups = SidebarActivityBucket.allCases.compactMap { bucket in
            byBucket[bucket].map { Group(bucket: bucket, chats: $0) }
        }
    }
}
