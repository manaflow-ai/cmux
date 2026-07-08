import CMUXMobileCore
public import Foundation

/// The opt-out gate the emitter consults before every capture and identify.
///
/// The analytics package must not depend on the settings domain (`CmuxSettings`),
/// so the telemetry opt-out is injected as this seam rather than read directly.
/// The app composition root provides a conformer backed by
/// `CmuxSettings.catalog.app.sendAnonymousTelemetry`; tests provide a fixed
/// value. The gate is evaluated *inside* the emitter so no fire-site can bypass
/// it.
public protocol AnalyticsConsentProviding: Sendable {
    /// Whether anonymous product telemetry may currently be sent.
    ///
    /// When `false`, the emitter drops every event and identify call and sends
    /// nothing over the network.
    var isTelemetryEnabled: Bool { get }
}

/// A consent provider backed by an injected closure.
///
/// Lets the composition root bridge the telemetry opt-out into the analytics
/// package without an import edge. The closure is read on each capture so a live
/// settings change takes effect immediately.
///
/// ```swift
/// let consent = AnalyticsConsentProvider { defaults.bool(forKey: "sendAnonymousTelemetry") }
/// ```
public struct AnalyticsConsentProvider: AnalyticsConsentProviding {
    private let isEnabled: @Sendable () -> Bool

    /// Wraps a closure that reports the current opt-out state.
    /// - Parameter isEnabled: Returns `true` when telemetry is allowed. Read on
    ///   every capture so a live toggle is honored without rewiring.
    public init(isEnabled: @escaping @Sendable () -> Bool) {
        self.isEnabled = isEnabled
    }

    public var isTelemetryEnabled: Bool { isEnabled() }
}

/// A consent provider backed by the shared telemetry opt-out in `UserDefaults`.
///
/// The iOS app cannot import the macOS-only `CmuxSettings` package, so this reads
/// the same backing key that `CmuxSettings.catalog.app.sendAnonymousTelemetry`
/// writes (`"sendAnonymousTelemetry"`), with the same default of `true`. The
/// value is read on every capture so toggling the Settings switch takes effect
/// immediately without rewiring.
public struct UserDefaultsAnalyticsConsentProvider: AnalyticsConsentProviding {
    /// The `UserDefaults` key shared with the settings catalog's
    /// `app.sendAnonymousTelemetry` entry.
    public static let telemetryKey = MobileTelemetryConsentStore.defaultsKey

    private let store: MobileTelemetryConsentStore

    /// Creates a consent provider over the given defaults.
    /// - Parameter defaults: The defaults store holding the opt-out flag. Inject
    ///   a suite-scoped store in tests; the app uses `.standard`.
    public init(defaults: UserDefaults) {
        self.store = MobileTelemetryConsentStore(defaults: defaults)
    }

    public var isTelemetryEnabled: Bool {
        store.isEnabled
    }
}
