import CmuxSettings
import Foundation

/// Whether the Cloud Machines surfaces are available: the local Beta Features
/// opt-in (`Settings › Beta Features › Cloud Machines`, also
/// `cloud.beta.machines.enabled` in `cmux.json`), unless a managed profile
/// disables Cloud. Off by default on every build. Every entry point
/// (right-sidebar Cloud tab, Settings section, command palette) and every
/// launch-time Cloud subsystem (``CloudActivationPolicy``) funnels through
/// this gate, so the toggle is the only way in.
enum CloudMachinesFeature {
    static var isEnabled: Bool {
        offMainIsEnabled()
    }

    /// The same answer from any isolation (right-sidebar mode availability,
    /// the activation policy).
    nonisolated static func offMainIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return false }
        return localOptIn(defaults: defaults)
    }

    /// The gate over an explicit managed-policy resolver and defaults, for tests.
    nonisolated static func isEnabled(defaults: UserDefaults, policy: ManagedDevicePolicy) -> Bool {
        guard !policy.isEnforced(.disableCloud) else { return false }
        return localOptIn(defaults: defaults)
    }

    nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().cloudMachines
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}
