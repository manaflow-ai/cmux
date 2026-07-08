import Foundation

/// Pure per-key limiter for terminal diagnostic recording and analytics.
public struct TerminalDiagnosticsRateLimiter: Sendable {
    private struct Bucket: Sendable {
        var windowStartedAt: Date
        var emittedInWindow: Int
        var lastEmittedAt: Date?
    }

    /// Maximum allowed events per key in one window.
    public var maxEventsPerWindow: Int
    /// Window length in seconds.
    public var window: TimeInterval
    /// Minimum spacing between allowed events for one key.
    public var minimumInterval: TimeInterval

    private var buckets: [String: Bucket] = [:]

    /// Creates a limiter.
    ///
    /// - Parameters:
    ///   - maxEventsPerWindow: Per-key cap. Defaults to twenty.
    ///   - window: Cap window in seconds. Defaults to thirty minutes.
    ///   - minimumInterval: Optional per-key spacing. Defaults to no spacing.
    public init(
        maxEventsPerWindow: Int = 20,
        window: TimeInterval = 30 * 60,
        minimumInterval: TimeInterval = 0
    ) {
        self.maxEventsPerWindow = maxEventsPerWindow
        self.window = window
        self.minimumInterval = minimumInterval
    }

    /// Returns whether an event for `key` should be allowed at `now`.
    public mutating func shouldAllow(key: String, now: Date) -> Bool {
        guard maxEventsPerWindow > 0 else { return false }
        var bucket = buckets[key] ?? Bucket(windowStartedAt: now, emittedInWindow: 0, lastEmittedAt: nil)
        if now.timeIntervalSince(bucket.windowStartedAt) >= window {
            bucket = Bucket(windowStartedAt: now, emittedInWindow: 0, lastEmittedAt: nil)
        }
        if let last = bucket.lastEmittedAt,
           minimumInterval > 0,
           now.timeIntervalSince(last) < minimumInterval {
            buckets[key] = bucket
            return false
        }
        guard bucket.emittedInWindow < maxEventsPerWindow else {
            buckets[key] = bucket
            return false
        }
        bucket.emittedInWindow += 1
        bucket.lastEmittedAt = now
        buckets[key] = bucket
        return true
    }

    /// Returns whether a repeated frame-drop count should be recorded.
    public static func shouldSampleFrameDrop(count: UInt64) -> Bool {
        count == 1 || count.isMultiple(of: 32)
    }
}
