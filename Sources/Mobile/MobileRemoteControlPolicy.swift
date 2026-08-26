import CmuxSettings
import Foundation

/// MDM master switch for the Mac acting as a remote view/control host for
/// the cmux iOS companion app.
///
/// When an administrator's configuration profile enforces
/// `DisableRemoteControl`, every hosting surface shuts off: the TCP
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
}
