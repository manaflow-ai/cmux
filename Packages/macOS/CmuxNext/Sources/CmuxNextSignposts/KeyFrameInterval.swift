public import os

/// An open ``SignpostName/keyToFrame`` interval returned by ``Signposter/begin(_:target:ageMicros:)``; end it
/// exactly once with the ``KeyFrameInterval`` overload of `Signposter.end(_:_:_:)`. A plain value (the signpost
/// id), so a key holds no heap state, unlike ``SignpostInterval``'s `OSSignpostIntervalState`.
public nonisolated struct KeyFrameInterval {
    /// The interval's `os_signpost_id_t` on the key log.
    let id: UInt64
    /// The MetricKit mirror's interval id, when the mirror was on at the begin (``SignpostMetricKitMirror``).
    var metricKitID: OSSignpostID?

    /// Whether the MetricKit mirror recorded this interval's begin (its end is mirrored too).
    public var isMirrored: Bool { metricKitID != nil }
}
