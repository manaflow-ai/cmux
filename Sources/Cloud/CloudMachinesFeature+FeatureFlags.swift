import CmuxCloud
import CmuxSettings
import Foundation

/// The Cloud availability answers that read the app's remote feature flags.
extension CloudMachinesFeature {
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
