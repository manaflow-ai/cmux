public import os

/// An open interval returned by ``Signposter/begin(_:_:)``; end it exactly once.
public nonisolated struct SignpostInterval {
    let state: OSSignpostIntervalState
    /// The MetricKit mirror's interval id, when the mirror was on at the begin (``SignpostMetricKitMirror``).
    var metricKitID: OSSignpostID?

    /// Whether the MetricKit mirror recorded this interval's begin (its end is mirrored too).
    public var isMirrored: Bool { metricKitID != nil }
}
