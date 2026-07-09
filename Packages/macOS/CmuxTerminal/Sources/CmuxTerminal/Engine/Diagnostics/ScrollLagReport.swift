internal import Foundation

/// A capture-worthy scroll-lag measurement emitted at the end of a scroll
/// session.
///
/// The probe accumulates per-tick lag while a scroll is in flight and, when the
/// accumulated stats clear the reporting thresholds, hands this value to the
/// report sink. Telemetry submission (Sentry) and the per-launch telemetry
/// opt-in gate stay app-side, so the package emits this pure `Sendable` value
/// rather than depending on a telemetry SDK.
public struct ScrollLagReport: Sendable, Equatable {
    /// The number of ticks sampled during the scroll session.
    public let samples: Int
    /// The mean per-tick lag in milliseconds.
    public let averageMs: Double
    /// The worst per-tick lag in milliseconds.
    public let maxMs: Double
    /// The lag threshold (ms) the session exceeded.
    public let thresholdMs: Double

    /// Creates a scroll-lag report.
    public init(samples: Int, averageMs: Double, maxMs: Double, thresholdMs: Double) {
        self.samples = samples
        self.averageMs = averageMs
        self.maxMs = maxMs
        self.thresholdMs = thresholdMs
    }
}
