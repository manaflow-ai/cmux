import Foundation

/// Read access to the launch-frozen anonymous-telemetry enablement.
///
/// Consumer code (Sentry/PostHog reporting, scroll-lag capture, launch
/// breadcrumbs) depends on this seam instead of the concrete
/// ``TelemetrySettingsStore`` so it can be tested with a fixed fake and never
/// names the storage mechanism.
public protocol TelemetrySettingsReading: Sendable {
    /// Whether anonymous telemetry is enabled, read once at process start and
    /// frozen for the lifetime of the launch so a settings change applies on
    /// the next restart rather than mid-session.
    var enabledForCurrentLaunch: Bool { get }
}
