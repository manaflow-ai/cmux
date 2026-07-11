/// Stable FSEvents watermark attached to watcher-triggered Git refreshes.
public nonisolated struct GitTrackedPathEventID: Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this ID is newer than `previous` in the FSEvents sequence.
    ///
    /// FSEvents IDs are unsigned serial numbers. RFC 1982 ordering treats a
    /// nonzero forward distance below half the sequence space as newer. The
    /// same comparison handles normal increments, counter wrap, duplicates,
    /// and delayed pre-wrap deliveries without changing modes after a reset.
    func isNewer(than previous: Self) -> Bool {
        let forwardDistance = rawValue &- previous.rawValue
        return forwardDistance != 0
            && forwardDistance < (UInt64.max / 2) + 1
    }
}

/// Reliability of a watcher event's source identity.
public nonisolated enum GitTrackedPathEventSource: Equatable, Sendable {
    /// A normal event with a monotonic FSEvents watermark.
    case stable(GitTrackedPathEventID)
    /// The event stream dropped data or requested a full rescan. Every delivery
    /// advances revision because it cannot be safely deduplicated.
    case unknown
    /// FSEvents IDs wrapped. Advances revision while preserving the last stable
    /// watermark; serial-number ordering accepts new low IDs and rejects delayed
    /// deliveries from before the wrap.
    case sequenceReset
}
