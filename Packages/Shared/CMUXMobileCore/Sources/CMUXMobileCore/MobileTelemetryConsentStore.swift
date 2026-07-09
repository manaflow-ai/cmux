public import Foundation

/// Shared persistence for the iOS product-analytics opt-in.
///
/// The store lives in `CMUXMobileCore` so the Settings UI and analytics emitter
/// use the same key and default without making the UI depend on the concrete
/// analytics package.
public struct MobileTelemetryConsentStore: Sendable {
    /// Defaults key read by Settings and by `CmuxMobileAnalytics`.
    public static let defaultsKey = "sendAnonymousTelemetry"

    /// Product analytics stay off until the user explicitly opts in.
    public static let defaultIsEnabled = false

    private let backing: MobileTelemetryConsentDefaultsBacking

    /// Creates a consent store over `defaults`.
    /// - Parameter defaults: The user defaults store. Use `.standard` in app
    ///   code and a suite-scoped store in tests.
    public init(defaults: UserDefaults) {
        self.backing = MobileTelemetryConsentDefaultsBacking(defaults: defaults)
    }

    /// Whether product analytics may be sent right now.
    public var isEnabled: Bool {
        backing.bool(forKey: Self.defaultsKey) ?? Self.defaultIsEnabled
    }

    /// Persists the user's current analytics consent.
    /// - Parameter isEnabled: `true` to allow analytics, `false` to opt out.
    public func setEnabled(_ isEnabled: Bool) {
        backing.set(isEnabled, forKey: Self.defaultsKey)
    }
}
