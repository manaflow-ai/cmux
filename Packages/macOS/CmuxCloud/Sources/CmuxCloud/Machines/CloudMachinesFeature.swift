import CmuxSettings
import Foundation

/// The one application-side Cloud availability decision. The effective
/// Cloud flag (including any permitted Nightly/debug override) must be enabled, the
/// Beta Features opt-in must be on, and no managed profile may disable Cloud.
/// Every Cloud entry point and background owner calls this policy; persisted
/// Cloud identities remain untouched when it returns false. The app supplies
/// the remote flag reads in `CloudMachinesFeature+FeatureFlags.swift`.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudMachinesFeature: Sendable {
    public nonisolated static var disabledMessage: String {
        if ManagedDevicePolicy().isEnforced(.disableCloud) { return ManagedCloudPolicy.disabledMessage }
        return String(localized: "cloud.feature.disabled", defaultValue: "Cloud Machines are temporarily unavailable.")
    }

    /// Pure decision helper for behavior tests and injected composition roots.
    /// The effective flag is supplied by CmuxFeatureFlags; the Beta Features
    /// toggle cannot bypass a disabled flag or managed policy.
    public nonisolated static func isEnabled(
        defaults: UserDefaults,
        policy: ManagedDevicePolicy,
        remoteEnabled: Bool
    ) -> Bool {
        guard !policy.isEnforced(.disableCloud) else { return false }
        return remoteEnabled && localOptIn(defaults: defaults)
    }

    public nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().cloudMachines
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}
