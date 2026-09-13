import CmuxSettings
import Foundation

/// Shared policy for discovering the account's other Macs. Incoming discovery
/// is controlled independently by `MobileRemoteControlPolicy`.
enum DevicesFeature {
    @MainActor
    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    /// Off-main mirror for the right-sidebar mode availability path and the
    /// mobile host listener gate. `policy` defaults to the resolver over
    /// `defaults`; tests inject one with a deterministic forced-value probe,
    /// since a real managed profile cannot be simulated.
    nonisolated static func isEnabled(
        defaults: UserDefaults = .standard,
        policy: ManagedDevicePolicy? = nil
    ) -> Bool {
        let policy = policy ?? ManagedDevicePolicy(defaults: defaults)
        guard !policy.isDeviceDiscoveryDisabled else { return false }
        return localOptIn(defaults: defaults)
    }

    nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        let key = DevicesCatalogSection().discoveryEnabled
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    nonisolated static func isDiscoveryEnabled(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults)
    }

    nonisolated static func isDiscoveryManaged(
        defaults: UserDefaults = .standard,
        policy: ManagedDevicePolicy? = nil
    ) -> Bool {
        (policy ?? ManagedDevicePolicy(defaults: defaults)).isDeviceDiscoveryDisabled
    }

    nonisolated static func isDiscoveryDisabledByPolicy(defaults: UserDefaults = .standard) -> Bool {
        isDiscoveryManaged(defaults: defaults)
    }
}
