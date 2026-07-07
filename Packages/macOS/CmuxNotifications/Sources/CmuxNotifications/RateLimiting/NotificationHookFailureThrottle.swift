public import Foundation

/// De-duplicates repeated notification-hook failure reports so a misbehaving
/// hook cannot flood the log or the user's notification center.
///
/// The throttle owns the per-key timestamp of the last reported failure and
/// decides whether a new failure for the same hook should surface. The owning
/// store keeps the side effects (logging, scheduling the user-facing alert)
/// app-side; only the suppress/allow decision lives here.
public struct NotificationHookFailureThrottle {
    /// Identifies a distinct failure stream by the failing hook and the source
    /// that registered it, so failures from different hooks throttle
    /// independently.
    public struct Key: Hashable {
        /// Identifier of the notification hook that failed.
        public let hookId: String
        /// Path of the source that registered the hook, if known.
        public let sourcePath: String?

        /// Creates a throttle key for a hook failure stream.
        public init(hookId: String, sourcePath: String?) {
            self.hookId = hookId
            self.sourcePath = sourcePath
        }
    }

    private let interval: TimeInterval
    private var lastFailureDateByKey: [Key: Date] = [:]

    /// Creates a throttle.
    /// - Parameter interval: Minimum spacing between surfaced failures for the
    ///   same key. Defaults to 300 seconds, matching the legacy store value.
    public init(interval: TimeInterval = 300) {
        self.interval = interval
    }

    /// Decides whether a hook failure should be surfaced, recording the report
    /// time when it is allowed.
    /// - Returns: `true` when the caller should report the failure (log + alert);
    ///   `false` when it falls within the throttle window of the previous report
    ///   for the same key and should be suppressed.
    public mutating func shouldReport(
        hookId: String,
        sourcePath: String?,
        now: Date = Date()
    ) -> Bool {
        let key = Key(hookId: hookId, sourcePath: sourcePath)
        if let lastDate = lastFailureDateByKey[key],
           now.timeIntervalSince(lastDate) < interval {
            return false
        }
        lastFailureDateByKey[key] = now
        return true
    }

    /// Removes stale throttle entries and caps the retained cache size.
    /// - Returns: Number of entries removed.
    public mutating func trim(
        now: Date,
        staleAge: TimeInterval,
        maxEntries: Int
    ) -> Int {
        let beforeCount = lastFailureDateByKey.count
        lastFailureDateByKey = Self.trimDateCache(
            lastFailureDateByKey,
            now: now,
            staleAge: staleAge,
            maxEntries: maxEntries
        )
        return Swift.max(0, beforeCount - lastFailureDateByKey.count)
    }

    private static func trimDateCache<Key: Hashable>(
        _ cache: [Key: Date],
        now: Date,
        staleAge: TimeInterval,
        maxEntries: Int
    ) -> [Key: Date] {
        let freshEntries = cache.filter { _, date in
            now.timeIntervalSince(date) <= staleAge
        }
        guard freshEntries.count > maxEntries else { return freshEntries }
        return Dictionary(
            uniqueKeysWithValues: freshEntries
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
    }
}
