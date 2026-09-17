import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    /// Applies browser string settings and validates the terminal-link placement enum.
    func applyBrowserStringSettings(
        from section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        applyStringSettings(
            BrowserSettingsFileMapping.stringSettings,
            from: section,
            snapshot: &snapshot
        )

        guard section.keys.contains("terminalLinkBrowserPlacement") else { return }
        guard let raw = jsonString(section["terminalLinkBrowserPlacement"]),
              let placement = TerminalLinkBrowserPlacement(rawValue: raw) else {
            logInvalid("browser.terminalLinkBrowserPlacement", sourcePath: sourcePath)
            return
        }
        snapshot.managedUserDefaults[BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey] = .string(
            placement.rawValue
        )
    }
}
