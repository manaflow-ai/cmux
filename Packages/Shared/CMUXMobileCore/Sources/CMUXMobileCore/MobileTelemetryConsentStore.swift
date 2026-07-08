public import Foundation

/// Shared persistence for the iOS product-analytics opt-out.
///
/// The store lives in `CMUXMobileCore` so the Settings UI and analytics emitter
/// use the same key and default without making the UI depend on the concrete
/// analytics package.
public struct MobileTelemetryConsentStore: Sendable {
    /// Defaults key read by Settings and by `CmuxMobileAnalytics`.
    public static let defaultsKey = "sendAnonymousTelemetry"

    /// Product analytics are enabled until the user opts out.
    public static let defaultIsEnabled = true

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a consent store over `defaults`.
    /// - Parameter defaults: The user defaults store. Use `.standard` in app
    ///   code and a suite-scoped store in tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether product analytics may be sent right now.
    public var isEnabled: Bool {
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? Self.defaultIsEnabled
    }

    /// Persists the user's current analytics consent.
    /// - Parameter isEnabled: `true` to allow analytics, `false` to opt out.
    public func setEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Self.defaultsKey)
    }
}
