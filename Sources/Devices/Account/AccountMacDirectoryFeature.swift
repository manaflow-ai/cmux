import Foundation

/// Gate for the per-user (cross-team) Mac directory. It applies only where
/// My Devices is available, and its remote flag is the rollback switch:
/// turning it off returns discovery and admission to the team directory alone.
/// It never affects iOS pairing, which stays on the team authority.
enum AccountMacDirectoryFeature {
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        DevicesFeature.isAvailable(defaults: defaults)
            && CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.macAccountDirectoryFlag)
    }
}
