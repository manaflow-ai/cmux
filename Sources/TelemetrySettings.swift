import CmuxSettings
import Foundation

enum TelemetrySettings {
    // Launch-frozen telemetry enablement: read once at process start so settings
    // changes apply on next restart. The persisted key, default, and read logic
    // live in `CmuxSettings` (`AppCatalogSection().sendAnonymousTelemetry`) as the
    // single source of truth; this anchor only freezes that read for the lifetime
    // of the launch.
    static let enabledForCurrentLaunch = resolveEnabled(
        userOptIn: AppCatalogSection().sendAnonymousTelemetry.value(in: .standard),
        policy: ManagedDevicePolicy()
    )

    /// `DisableTelemetry` (MDM) wins over the user opt-in. Frozen for the
    /// launch like the opt-in itself, so a profile pushed mid-session applies
    /// at the next launch; Settings shows the managed state immediately.
    static func resolveEnabled(userOptIn: Bool, policy: ManagedDevicePolicy) -> Bool {
        userOptIn && !policy.isEnforced(.disableTelemetry)
    }
}
