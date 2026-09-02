import CmuxSettings
import Foundation

/// Whether the Cloud Machines surfaces are available: the remote rollout flag
/// or the local Beta Features opt-in. Every entry point (right-sidebar Cloud
/// tab, Settings section, command palette, titlebar button, new-workspace
/// menu) funnels through this gate so a nightly user who flips the beta
/// toggle gets exactly the surfaces a remote rollout would enable.
enum CloudMachinesFeature {
    @MainActor
    static var isEnabled: Bool {
        isEnabled(defaults: .standard, remoteEnabled: CmuxFeatureFlags.shared.isCloudVMUIEnabled)
    }

    /// Off-main mirror for the right-sidebar mode availability path.
    nonisolated static func offMainIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        CmuxFeatureFlags.offMainIsCloudVMUIEnabled || localOptIn(defaults: defaults)
    }

    nonisolated static func isEnabled(defaults: UserDefaults, remoteEnabled: Bool) -> Bool {
        remoteEnabled || localOptIn(defaults: defaults)
    }

    nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().cloudMachines
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}
