/// Stable FSEvents watermark attached to watcher-triggered Git refreshes.
public nonisolated struct GitTrackedPathEventID: Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Reliability of a watcher event's source identity.
public nonisolated enum GitTrackedPathEventSource: Equatable, Sendable {
    /// A normal event with a monotonic FSEvents watermark.
    case stable(GitTrackedPathEventID)
    /// The event stream dropped data or requested a full rescan. Every delivery
    /// advances revision because it cannot be safely deduplicated.
    case unknown
    /// FSEvents IDs wrapped. Advances revision and disables stable-ID dedupe for
    /// this repository until process restart, because delayed pre-wrap events
    /// cannot be distinguished from the new lower sequence.
    case sequenceReset
}
