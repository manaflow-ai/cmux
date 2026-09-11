import CmuxSettings
import Foundation

extension MobileHostService {
    /// `devicesPublishing` is the Devices sidebar opt-in after managed policy
    /// (``DevicesFeature/isEnabled(defaults:policy:)``): that opt-in is a
    /// promise to be visible and controllable from the account's other Macs,
    /// which needs this Mac to serve its workspace tree, so the listener runs
    /// while it is on even if iOS pairing was never set up (or was turned off).
    /// A remote-control ban makes it false, and the pairing overrides decide.
    nonisolated static func isListeningEnabled(
        defaults: UserDefaults,
        buildFlavor: BuildFlavor,
        devicesPublishing: Bool
    ) -> Bool {
        guard MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults) else { return false }
        if devicesPublishing {
            return true
        }
        if let override = defaults.object(forKey: listeningEnabledDefaultsKey) as? Bool {
            return override
        }
        if let legacyOverride = defaults.object(forKey: legacyListeningEnabledDefaultsKey) as? Bool {
            return legacyOverride
        }
        return buildFlavor != .stable
    }

}
