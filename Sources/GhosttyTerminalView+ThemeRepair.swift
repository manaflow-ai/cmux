import Foundation
import CmuxTerminalCore

extension GhosttyApp {
    /// Scans cmux app-support config files and returns the last extracted value.
    private func cmuxAppSupportConfigValue(
        extracting: (String) -> String?
    ) -> String? {
        #if os(macOS)
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
        var lastValue: String?
        for url in configURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let value = extracting(contents) else {
                continue
            }
            lastValue = value
        }
        return lastValue
        #else
        return nil
        #endif
    }

    /// Returns the normalized value from the active cmux-managed Ghostty config.
    ///
    /// The caller injects the returned value into the live Ghostty config after
    /// the on-disk files have loaded, so legacy single-sided values are repaired
    /// without rewriting user files during startup.
    func currentCmuxManagedThemeRepairValue() -> String? {
        cmuxAppSupportConfigValue {
            GhosttyConfig.normalizedCmuxManagedThemeValue(in: $0)
        }
    }

    /// Returns the last raw theme directive found in cmux app-support config files.
    // This remains internal because the configuration reload path is declared
    // in GhosttyTerminalView.swift while the shared scanner lives here.
    func currentCmuxAppSupportThemeValue() -> String? {
        cmuxAppSupportConfigValue {
            GhosttyConfig.lastThemeDirective(in: $0)
        }
    }
}
