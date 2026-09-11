import CmuxSettings
import Foundation

/// Whether the Devices surfaces are available: the Beta Features opt-in, minus
/// a managed-device remote-control ban. Every entry point (Cloud sidebar’s My Devices
/// section, the Cloud shortcut, `cmux right-sidebar set devices`, the settings
/// row, this Mac publishing itself to the account's other Macs) funnels through
/// this gate, mirroring ``CloudMachinesFeature`` for the Cloud tab.
///
/// This is a local Beta setting, not a remote PostHog flag: it is the same
/// control plane the Cloud tab uses (`cloud.beta.machines.enabled`), and the
/// feature is a per-Mac opt-in to being visible and controllable from the
/// account's other Macs, which a remote rollout must never flip on silently.
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
        let key = BetaFeaturesCatalogSection().devices
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    nonisolated static func isDiscoveryEnabled(defaults: UserDefaults = .standard) -> Bool {
        let key = DevicesCatalogSection().discoveryEnabled
        let discovery = defaults.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
        return isEnabled(defaults: defaults) && discovery
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

extension RightSidebarBetaFeatureSettings {
    /// Same key as ``BetaFeaturesCatalogSection/devices``; the right-sidebar
    /// mode bar observes it through `@AppStorage`.
    static let devicesEnabledKey = "devices.beta.enabled"
    static let defaultDevicesEnabled = false

    nonisolated static func isDevicesEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: devicesEnabledKey) != nil else { return defaultDevicesEnabled }
        return defaults.bool(forKey: devicesEnabledKey)
    }
}
