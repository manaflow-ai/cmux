public import Foundation

/// A consent provider backed by the shared telemetry opt-in in `UserDefaults`.
///
/// This provider reads the same backing key as the app's anonymous-telemetry
/// setting. A missing value is off: telemetry is opt-in, so a fresh install
/// sends nothing until the person turns it on (Leo, 2026-11-24: "whatever we
/// do, we need to make sure it's opt out by defautl i assume?"). Every access
/// reads the store again so live setting changes apply without rebuilding
/// consumers.
///
/// ```swift
/// let consent = UserDefaultsAnalyticsConsentProvider(defaults: .standard)
/// if consent.isTelemetryEnabled {
///     // Start telemetry infrastructure.
/// }
/// ```
public struct UserDefaultsAnalyticsConsentProvider: AnalyticsConsentProviding {
    /// The `UserDefaults` key shared with the anonymous-telemetry setting.
    public static let telemetryKey = "sendAnonymousTelemetry"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a consent provider over the given defaults store.
    ///
    /// - Parameter defaults: The store holding the opt-in flag. Inject a
    ///   suite-scoped store in tests; the app uses `.standard`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether the person turned anonymous product telemetry on in the defaults store.
    public var isTelemetryEnabled: Bool {
        defaults.object(forKey: Self.telemetryKey) as? Bool ?? false
    }
}
