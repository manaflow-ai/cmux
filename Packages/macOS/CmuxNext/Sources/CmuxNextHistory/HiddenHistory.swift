public import Foundation

/// What Clear History and Remove from History hid of history the app does
/// not own and cannot delete (the daemon's append-only session journal):
/// cleared time ranges and single entries (plans/cmux-next/history.md 3).
/// Personal state, stored in the home session's projection `history.hidden`.
public nonisolated struct HiddenHistory: Hashable, Sendable, Codable {
    public struct Range: Hashable, Sendable, Codable {
        public var from: Date
        public var until: Date
    }

    public static let schemaVersion: UInt32 = 1
    public static let rangeLimit = 64
    public static let entryLimit = 2_000

    /// Oldest first.
    public private(set) var ranges: [Range] = []
    /// Hidden entry ids (`AgentSession.qualifiedID`), oldest first.
    public private(set) var entries: [String] = []

    public init() {}

    /// Hides everything active from `since` (nil: all time) until `now`.
    /// Later activity shows again.
    public mutating func hide(since: Date?, now: Date) {
        ranges.append(Range(from: since ?? .distantPast, until: now))
        if ranges.count > Self.rangeLimit { ranges.removeFirst(ranges.count - Self.rangeLimit) }
    }

    public mutating func hide(entry id: String) {
        guard !entries.contains(id) else { return }
        entries.append(id)
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
    }

    public func hides(_ id: String, activeAt time: Date) -> Bool {
        entries.contains(id) || ranges.contains { $0.from <= time && time <= $0.until }
    }

    /// Both documents' hides (a conflict merge keeps every clear).
    public func merged(with other: HiddenHistory) -> HiddenHistory {
        var result = self
        for range in other.ranges where !result.ranges.contains(range) { result.ranges.append(range) }
        result.ranges.sort { $0.until < $1.until }
        if result.ranges.count > Self.rangeLimit { result.ranges.removeFirst(result.ranges.count - Self.rangeLimit) }
        for id in other.entries { result.hide(entry: id) }
        return result
    }
}
