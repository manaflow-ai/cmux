import CmuxSettings
import Foundation

/// MDM master switch for the Mac acting as a remote view/control host for
/// the cmux iOS companion app.
///
/// When an administrator's configuration profile enforces
/// `DisableRemoteControl`, every hosting surface shuts off: the Iroh host
/// runtime (including its Bonjour LAN advertisement), the legacy TCP
/// pairing listener, the universal transport-admission funnel, and the
/// pairing flow. The policy gates the Mac acting as a *server*; outbound
/// features (Sparkle updates, notification forwarding to the phone,
/// Mac-as-client SSH) and the local automation Unix socket are out of
/// scope.
enum MobileRemoteControlPolicy {
    /// Process-wide resolver for profile-forced policy values.
    private static let managedDevicePolicy = ManagedDevicePolicy()

    /// Test-only override: real forced values cannot be simulated without
    /// installing a configuration profile. nonisolated(unsafe): written only
    /// by `.serialized` test suites; the app never mutates it.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    /// Whether the configuration profile disables remote control.
    static var isDisabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        return managedDevicePolicy.isEnforced(.disableRemoteControl)
    }

    /// Convenience inverse of ``isDisabled``.
    static var isEnabled: Bool { !isDisabled }

    /// User availability and managed policy both gate every incoming transport.
    /// Outgoing device connections use their own discovery preference.
    static func allowsIncomingAccess(defaults: UserDefaults = .standard) -> Bool {
        let key = DevicesCatalogSection().incomingAccessEnabled
        let enabled = defaults.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
        let policy = ManagedDevicePolicy(defaults: defaults)
        let broadAllowed = overrideForTesting.map { !$0 }
            ?? !policy.isEnforced(.disableRemoteControl)
        let managedAllowed = broadAllowed && !policy.isIncomingDeviceAccessDisabled
        return managedAllowed && enabled
    }

    /// Whether MDM independently blocks discovery of other Macs.
    static func isDeviceDiscoveryDisabled(defaults: UserDefaults = .standard) -> Bool {
        ManagedDevicePolicy(defaults: defaults).isDeviceDiscoveryDisabled
    }

    /// Whether MDM independently blocks this Mac from accepting sessions.
    static func isIncomingAccessDisabled(defaults: UserDefaults = .standard) -> Bool {
        ManagedDevicePolicy(defaults: defaults).isIncomingDeviceAccessDisabled
    }

    /// Whether incoming access is managed by either the dedicated or broad ban.
    static func isIncomingAccessManaged(
        defaults: UserDefaults = .standard,
        policy: ManagedDevicePolicy? = nil
    ) -> Bool {
        (policy ?? ManagedDevicePolicy(defaults: defaults)).isIncomingDeviceAccessDisabled
    }
}
