public import os

/// An open ``SignpostName/keyToFrame`` interval returned by ``Signposter/begin(_:target:ageMicros:)``; end it
/// exactly once with the ``KeyFrameInterval`` overload of `Signposter.end(_:_:_:)`. A plain value (the signpost
/// id, the begin time and the ring slice), so a key holds no heap state, unlike ``SignpostInterval``'s
/// `OSSignpostIntervalState`.
public nonisolated struct KeyFrameInterval {
    /// The interval's `os_signpost_id_t` on the key log.
    let id: UInt64
    /// The MetricKit mirror's interval id, when the mirror was on at the begin (``SignpostMetricKitMirror``).
    var metricKitID: OSSignpostID?
    /// `CLOCK_UPTIME_RAW` nanoseconds when the interval began (the trace ring's clock).
    public let beginUptimeNanos: UInt64
    /// The trace ring slice the begin opened (an async slice keyed by the signpost id), or nil when the key
    /// category was off then.
    let ring: SignpostInterval.Ring?

    /// Whether the MetricKit mirror recorded this interval's begin (its end is mirrored too).
    public var isMirrored: Bool { metricKitID != nil }

    /// Whether the begin wrote a trace ring record (its end writes one too).
    public var isTraced: Bool { ring != nil }
}
