import CmuxNextCompat

/// An open interval returned by ``Signposter/begin(_:_:)``; end it exactly once.
public nonisolated struct SignpostInterval {
    let state: OSSignpostIntervalState
    /// The MetricKit mirror's interval id, when the mirror was on at the begin (``SignpostMetricKitMirror``).
    var metricKitID: OSSignpostID?
    /// `CLOCK_UPTIME_RAW` nanoseconds when the interval began: the trace ring's clock (plans/cmux-next/trace.md),
    /// `NSEvent.timestamp`'s and the action budget's, so an end can measure the interval without a second begin read.
    public let beginUptimeNanos: UInt64
    /// The trace ring slice the begin opened, or nil when its category was off then: the end writes a ring
    /// record only for a begin that wrote one, so the ring never holds an end without its begin.
    let ring: Ring?

    /// Whether the MetricKit mirror recorded this interval's begin (its end is mirrored too).
    public var isMirrored: Bool { metricKitID != nil }

    /// Whether the begin wrote a trace ring record (its end writes one too).
    public var isTraced: Bool { ring != nil }

    /// How the interval is recorded in the trace ring.
    enum Ring: Equatable {
        /// A same-thread slice (B/E): the interval begins and ends on one thread, nested in that thread's slices.
        case thread
        /// An async slice (AB/AE) keyed by `id`: it may end in a later turn, on another thread, or overlap
        /// another interval of the same name.
        case async(id: UInt64)
    }
}
