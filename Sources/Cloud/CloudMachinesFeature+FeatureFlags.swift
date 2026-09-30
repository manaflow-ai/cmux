import CmuxCloud
import CmuxSettings
import Foundation

/// The Cloud availability answers that read the app's remote feature flags.
extension CloudMachinesFeature {
    /// Whether Cloud can be discovered on this Mac. This is the rollout and
    /// managed-policy decision; it intentionally does not include the local
    /// activation marker so the Cloud tab can host first-use enablement.
    @MainActor static var isAvailable: Bool {
        return isAvailable(
            policy: ManagedDevicePolicy(),
            remoteEnabled: CmuxFeatureFlags.shared.isCloudMachinesEnabled
        )
    }

    /// Off-main mirror of ``isAvailable`` for right-sidebar mode resolution.
    nonisolated static func offMainIsAvailable(defaults: UserDefaults = .standard) -> Bool {
        _ = defaults
        return isAvailable(
            policy: ManagedDevicePolicy(),
            remoteEnabled: CmuxFeatureFlags.offMainEffectiveValue(
                for: CmuxFeatureFlags.cloudMachinesFlag
            )
        )
    }

    /// Pure availability decision for tests and injected callers.
    nonisolated static func isAvailable(
        policy: ManagedDevicePolicy,
        remoteEnabled: Bool
    ) -> Bool {
        !policy.isEnforced(.disableCloud) && remoteEnabled
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
}
