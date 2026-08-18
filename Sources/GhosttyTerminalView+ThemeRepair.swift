import Foundation
import CmuxTerminalCore

extension GhosttyApp {
    /// Returns the normalized value from the active cmux-managed Ghostty config.
    ///
    /// The caller injects the returned value into the live Ghostty config after
    /// the on-disk files have loaded, so legacy single-sided values are repaired
    /// without rewriting user files during startup.
    func currentCmuxManagedThemeRepairValue() -> String? {
        let fileManager = FileManager.default
        guard let appSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let configURLs = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
        var repairedThemeValue: String?
        for url in configURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let normalized = GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents) {
                repairedThemeValue = normalized
            }
        }
        return repairedThemeValue
    }
}
