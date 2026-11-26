import CmuxSettings
import Foundation

/// The one application-side Cloud activation decision. Cloud is available to
/// every user unless a managed profile disables it; the persisted first-use
/// activation marker controls whether Cloud work may run. The right-sidebar
/// discoverability check intentionally omits the activation marker so the
/// Cloud tab can own first-use enablement.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudMachinesFeature: Sendable {
    public nonisolated static var disabledMessage: String {
        if ManagedDevicePolicy().isEnforced(.disableCloud) { return ManagedCloudPolicy.disabledMessage }
        return String(localized: "cloud.feature.disabled", defaultValue: "Cloud Machines are temporarily unavailable.")
    }

    /// Whether Cloud can be discovered on this Mac.
    public nonisolated static func isAvailable(policy: ManagedDevicePolicy) -> Bool {
        !policy.isEnforced(.disableCloud)
    }

    /// Whether Cloud work is enabled after local first-use activation.
    public nonisolated static func isEnabled(
        defaults: UserDefaults,
        policy: ManagedDevicePolicy
    ) -> Bool {
        isAvailable(policy: policy) && localOptIn(defaults: defaults)
    }

    public nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().cloudMachines
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}
