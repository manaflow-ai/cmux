public import Foundation

/// What Clear History and Remove from History hid of history the app does
/// not own and cannot delete (the daemon's append-only session journal):
/// cleared time ranges and single entries (plans/cmux-next/history.md 3).
/// Personal state, stored in the home session's projection `history.hidden`.
public nonisolated struct HiddenHistory: Hashable, Sendable, Codable {
    public struct Range: Hashable, Sendable, Codable {
        public var from: Date
        public var until: Date
        /// The entry kind it clears (`agent`, `command`); nil: every kind.
        public var kind: String?

        /// This range with both ends at whole Unix milliseconds, the precision the daemon stores
        /// (cmux-history `HiddenRange`), so a local hide equals its daemon copy (cmux#38381).
        public var daemonRounded: Range {
            Range(from: HiddenHistory.daemonRounded(from), until: HiddenHistory.daemonRounded(until), kind: kind)
        }
    }

    /// `date` at whole Unix milliseconds, the way the daemon rounds it (`unix_ms`, then back to seconds).
    public static func daemonRounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
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
    public mutating func hide(since: Date?, now: Date, kind: String? = nil) {
        ranges.append(Range(from: since ?? .distantPast, until: now, kind: kind).daemonRounded)
        if ranges.count > Self.rangeLimit { ranges.removeFirst(ranges.count - Self.rangeLimit) }
    }

    public mutating func hide(entry id: String) {
        guard !entries.contains(id) else { return }
        entries.append(id)
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
    }

    public func hides(_ id: String, activeAt time: Date, kind: String? = nil) -> Bool {
        entries.contains(id) || ranges.contains { range in
            (range.kind == nil || range.kind == kind) && range.from <= time && time <= range.until
        }
    }

    /// Both documents' hides (a conflict merge keeps every clear).
    public func merged(with other: HiddenHistory) -> HiddenHistory {
        var result = self
        // Ranges at daemon precision, so a local clear and its daemon copy are one range.
        var seen = Set<Range>()
        result.ranges = result.ranges.map(\.daemonRounded).filter { seen.insert($0).inserted }
        for range in other.ranges.map(\.daemonRounded) where !result.ranges.contains(range) { result.ranges.append(range) }
        result.ranges.sort { $0.until < $1.until }
        if result.ranges.count > Self.rangeLimit { result.ranges.removeFirst(result.ranges.count - Self.rangeLimit) }
        for id in other.entries { result.hide(entry: id) }
        return result
    }
}
