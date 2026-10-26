public import Foundation

/// A consent provider backed by the shared telemetry opt-out in `UserDefaults`.
///
/// This provider reads the same backing key as the app's anonymous-telemetry
/// setting. A missing value defaults to enabled (the Settings toggle is the
/// opt-out; its `@AppStorage` default in `MobileSettingsView` must stay in
/// sync with the fallback here), and every access reads the store again so
/// live setting changes apply without rebuilding consumers.
///
/// It keeps the defaults domain's name, not a `UserDefaults` object (which is
/// not `Sendable`), and opens the domain at each read; nil is the app's
/// standard domain.
///
/// ```swift
/// let consent = UserDefaultsAnalyticsConsentProvider()
/// if consent.isTelemetryEnabled {
///     // Start telemetry infrastructure.
/// }
/// ```
public struct UserDefaultsAnalyticsConsentProvider: AnalyticsConsentProviding {
    /// The `UserDefaults` key shared with the anonymous-telemetry setting.
    public static let telemetryKey = "sendAnonymousTelemetry"

    private let suiteName: String?

    /// Creates a consent provider over the given defaults domain.
    ///
    /// - Parameter suiteName: The domain holding the opt-out flag, or nil for
    ///   the app's standard domain. Tests pass their own suite.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    /// Whether anonymous product telemetry is enabled in the defaults store.
    public var isTelemetryEnabled: Bool {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return defaults.object(forKey: Self.telemetryKey) as? Bool ?? true
    }
}
