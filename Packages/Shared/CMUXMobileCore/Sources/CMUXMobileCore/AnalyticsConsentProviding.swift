/// The shared opt-out gate consulted before sending telemetry.
///
/// Analytics and crash-reporting infrastructure depend on this lower-level
/// seam so both obey the same live consent source without depending on each
/// other.
public protocol AnalyticsConsentProviding: Sendable {
    /// Whether anonymous product telemetry may currently be sent.
    ///
    /// A conformer must return its current value on every read so consent
    /// changes take effect without rebuilding the telemetry graph.
    var isTelemetryEnabled: Bool { get }
}
