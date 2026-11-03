import CmuxSettings
import Foundation

extension BrowserLinkOpenSettings {
    static let terminalLinkBrowserPlacementKey = SettingCatalog().browser.terminalLinkBrowserPlacement.userDefaultsKey

    static func terminalLinkBrowserPlacement(defaults: UserDefaults = .standard) -> TerminalLinkBrowserPlacement {
        defaults.string(forKey: terminalLinkBrowserPlacementKey)
            .flatMap(TerminalLinkBrowserPlacement.init(rawValue:)) ?? .split
    }
}

extension CmuxSettingsFileStore {
    func parseTerminalLinkBrowserPlacement(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard section.keys.contains("terminalLinkBrowserPlacement") else { return }
        if let raw = jsonString(section["terminalLinkBrowserPlacement"]),
           let placement = TerminalLinkBrowserPlacement(rawValue: raw) {
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey] = .string(placement.rawValue)
        } else {
            logInvalid("browser.terminalLinkBrowserPlacement", sourcePath: sourcePath)
        }
    }
}
