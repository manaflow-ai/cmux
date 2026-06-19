import Foundation

/// Repository for anonymous-telemetry enablement, persisted in `UserDefaults`
/// under the catalog's `app.sendAnonymousTelemetry` key.
///
/// Launch-freeze: the persisted value is read once, at construction, and held
/// for the instance's lifetime. The composition root builds exactly one store
/// at process start, so the enablement is frozen for the launch and a settings
/// change takes effect on the next restart. The persisted key, default, and
/// read logic live in ``AppCatalogSection/sendAnonymousTelemetry`` as the
/// single source of truth; this store only freezes that read.
///
/// Isolation: an immutable `Sendable` struct, not an actor. The frozen `Bool`
/// is captured at init and never mutates, so there is nothing for an actor to
/// protect and synchronous, non-awaiting readers (breadcrumbs, scroll-lag
/// capture) can read it directly.
public struct TelemetrySettingsStore: TelemetrySettingsReading {
    public let enabledForCurrentLaunch: Bool

    /// Creates a store and freezes the telemetry enablement from the given
    /// defaults suite at construction time.
    public init(defaults: UserDefaults) {
        self.enabledForCurrentLaunch = AppCatalogSection()
            .sendAnonymousTelemetry
            .value(in: defaults)
    }
}
