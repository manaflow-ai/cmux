public import CMUXMobileCore

/// A consent provider backed by an injected closure.
///
/// The closure is read on each capture so a live settings change takes effect
/// immediately.
///
/// ```swift
/// let consent = AnalyticsConsentProvider {
///     settings.sendAnonymousTelemetry
/// }
/// ```
public struct AnalyticsConsentProvider: AnalyticsConsentProviding {
    private let isEnabled: @Sendable () -> Bool

    /// Wraps a closure that reports the current opt-out state.
    ///
    /// - Parameter isEnabled: Returns `true` when telemetry is allowed. Read on
    ///   every capture so a live toggle is honored without rewiring.
    public init(isEnabled: @escaping @Sendable () -> Bool) {
        self.isEnabled = isEnabled
    }

    /// Whether anonymous product telemetry may currently be sent.
    public var isTelemetryEnabled: Bool { isEnabled() }
}
