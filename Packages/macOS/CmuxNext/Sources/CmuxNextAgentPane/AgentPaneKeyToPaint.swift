import Foundation

/// One key-to-paint histogram from the agent page's probe (`pane.keyToPaint`, webviews/src/ui/frameInput.ts):
/// each keydown's timestamp to the next frame plus one task, in fixed buckets, at most once per 10 s and
/// only while the host has the probe on (``AgentPaneView/setKeyToPaintProbe(_:)``). Numbers only.
public nonisolated struct AgentPaneKeyToPaint: Equatable, Sendable {
    /// The most bucket bounds a report may carry.
    public static let maximumBounds = 32

    /// Upper bounds of the buckets in milliseconds, increasing; ``counts`` has one more bucket for
    /// everything above the last.
    public let boundsMilliseconds: [Double]
    /// Keys per bucket.
    public let counts: [Int]
    /// Keys measured (the sum of ``counts``).
    public let count: Int
    public let sumMilliseconds: Double
    public let maxMilliseconds: Double
    /// The report's window, from the previous report (or the probe turning on) to this one.
    public let windowMilliseconds: Double

    /// The report in `params`, or nil when it breaks the shape: bounds not increasing, a count
    /// that is not a whole non-negative number, counts that do not add up, a negative or
    /// non-finite time.
    init?(params: [String: Any]?) {
        guard let params, let bounds = Self.numbers(params["bounds_ms"]), (1...Self.maximumBounds).contains(bounds.count),
              zip(bounds, bounds.dropFirst()).allSatisfy({ $0 < $1 }), bounds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let rawCounts = Self.numbers(params["counts"]), rawCounts.count == bounds.count + 1,
              let total = Self.number(params["count"]).flatMap(Self.whole),
              let sum = Self.number(params["sum_ms"]), let max = Self.number(params["max_ms"]),
              let window = Self.number(params["window_ms"]),
              [sum, max, window].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let counts = rawCounts.compactMap(Self.whole)
        guard counts.count == rawCounts.count, counts.reduce(0, +) == total else { return nil }
        boundsMilliseconds = bounds
        self.counts = counts
        count = total
        sumMilliseconds = sum
        maxMilliseconds = max
        windowMilliseconds = window
    }

    /// A JSON number as the page's message carries it (an `NSNumber`); nil for anything else, a
    /// boolean included.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        guard let items = value as? [Any] else { return nil }
        let numbers = items.compactMap(number)
        return numbers.count == items.count ? numbers : nil
    }

    /// `value` as a count: whole, non-negative and at most a billion (so the sum cannot overflow).
    private static func whole(_ value: Double) -> Int? {
        guard value >= 0, value <= 1_000_000_000, let whole = Int(exactly: value) else { return nil }
        return whole
    }
}
