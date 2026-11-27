import CmuxSettings
import Foundation

/// MDM enforcement for the embedded-browser gate.
///
/// `BrowserAvailabilitySettings.isDisabled()` consults this before the
/// user-level `browserDisabledOverride` value, making the
/// `DisableEmbeddedBrowser` configuration-profile key tier 0: it wins over
/// user settings, `cmux.json` imports, and defaults, and no in-app writer
/// (Settings toggle, command palette, CLI) can change it.
extension BrowserAvailabilitySettings {
    /// Process-wide resolver for profile-forced policy values.
    private static let managedDevicePolicy = ManagedDevicePolicy()

    /// Test-only override for the managed-policy check: real forced values
    /// cannot be simulated without installing a configuration profile.
    /// nonisolated(unsafe): written only by `.serialized` test suites; the
    /// app never mutates it.
    nonisolated(unsafe) static var managedPolicyOverrideForTesting: Bool?

    /// Whether an administrator's configuration profile disables the
    /// embedded browser — via the dedicated policy key or by forcing the
    /// user-level key to true directly. When `true` the gate is locked: the
    /// user cannot re-enable it, and no creation path — including session
    /// restore and layout application — may build a browser pane.
    static var isManagedByPolicy: Bool {
        if let managedPolicyOverrideForTesting { return managedPolicyOverrideForTesting }
        return managedDevicePolicy.isBrowserDisableLocked(
            browserDisabledUserDefaultsKey: disabledKey
        )
    }
}
