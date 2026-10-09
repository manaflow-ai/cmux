public import Foundation

/// What a chat needs from the person, most urgent first: the order of the
/// Activity view's Priority section (meeting 2026-10-08, AV). acpmux owns
/// the facts (a pending permission or question, a failed last turn, a turn
/// that finished while no client watched); the sidebar only orders them.
public nonisolated enum SidebarActivityAttention: Int, Hashable, Sendable, CaseIterable, Comparable {
    /// The turn waits for an approval or an answer.
    case needsInput
    /// The last turn failed.
    case failed
    /// A reply the person has not opened yet.
    case unread

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One chat as the Activity view shows it: a title and a one-line preview
/// of its latest message.
public nonisolated struct SidebarActivityChat: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var harness: String
    public var brand: String?
    public var updatedAt: Date
    public var attention: SidebarActivityAttention?
    public var preview: String?

    public init(id: String, title: String, harness: String, brand: String? = nil, updatedAt: Date,
                attention: SidebarActivityAttention? = nil, preview: String? = nil) {
        self.id = id; self.title = title; self.harness = harness; self.brand = brand
        self.updatedAt = updatedAt; self.attention = attention; self.preview = preview
    }
}

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
