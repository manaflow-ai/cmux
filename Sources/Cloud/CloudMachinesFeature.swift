import CmuxSettings
import Foundation

/// The one application-side Cloud availability decision. The remote
/// Cloud kill switch must be enabled, the existing
/// Beta Features opt-in must be on, and no managed profile may disable Cloud.
/// Every Cloud entry point and background owner calls this policy; persisted
/// Cloud identities remain untouched when it returns false.
enum CloudMachinesFeature {
    nonisolated static var disabledMessage: String {
        if ManagedDevicePolicy().isEnforced(.disableCloud) { return ManagedCloudPolicy.disabledMessage }
        return String(localized: "cloud.feature.disabled", defaultValue: "Cloud Machines are temporarily unavailable.")
    }

    @MainActor static var isEnabled: Bool {
        isEnabled(defaults: .standard, policy: ManagedDevicePolicy(),
                  remoteEnabled: CmuxFeatureFlags.shared.isCloudMachinesEnabled)
    }

    /// The same answer from any isolation (right-sidebar mode availability,
    /// the activation policy).
    nonisolated static func offMainIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return false }
        return CmuxFeatureFlags.offMainEffectiveValue(
            for: CmuxFeatureFlags.cloudMachinesFlag
        )
            && localOptIn(defaults: defaults)
    }

    /// The gate over an explicit managed-policy resolver and defaults, for tests.
    nonisolated static func isEnabled(defaults: UserDefaults, policy: ManagedDevicePolicy) -> Bool {
        guard !policy.isEnforced(.disableCloud) else { return false }
        return CmuxFeatureFlags.offMainEffectiveValue(
            for: CmuxFeatureFlags.cloudMachinesFlag
        )
            && localOptIn(defaults: defaults)
    }

    /// Pure decision helper for behavior tests and injected composition roots.
    /// The remote value is authoritative: a false rollout cannot be bypassed
    /// by the local Beta Features toggle.
    nonisolated static func isEnabled(
        defaults: UserDefaults,
        policy: ManagedDevicePolicy,
        remoteEnabled: Bool
    ) -> Bool {
        guard !policy.isEnforced(.disableCloud) else { return false }
        return remoteEnabled && localOptIn(defaults: defaults)
    }

    nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().cloudMachines
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}
