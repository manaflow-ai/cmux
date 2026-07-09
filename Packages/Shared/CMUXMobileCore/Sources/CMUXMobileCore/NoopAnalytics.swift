import Foundation

/// An ``AnalyticsEmitting`` that drops every event.
///
/// Use it as the default for SwiftUI previews, unit tests that don't assert on
/// analytics, and any call site that has no real emitter to inject. It does no
/// work, holds no state, and is safe to share across actors.
///
/// ```swift
/// let store = MobileShellComposite(analytics: NoopAnalytics())
/// ```
public struct NoopAnalytics: AnalyticsEmitting {
    /// Creates a no-op emitter.
    public init() {}

    public func capture(_ event: String, _ properties: [String: AnalyticsValue]) {}

    public func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}

    public func setSuperProperties(_ properties: [String: AnalyticsValue]) {}

    /// Ignores telemetry consent updates because this emitter never sends analytics.
    public func setTelemetryConsentEnabled(_ isEnabled: Bool) {}

    public func flush() async {}
}
