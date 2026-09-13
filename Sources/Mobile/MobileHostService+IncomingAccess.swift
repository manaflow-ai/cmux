import CmuxSettings
import Foundation

extension MobileHostService {
    /// Discoverability owns incoming sessions independently of whether this Mac
    /// discovers peers. An administrator ban and the incoming-access preference
    /// are checked before any listener override.
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
