import CmuxSettings
import Foundation

extension BrowserLinkOpenSettings {
    /// UserDefaults key for the terminal-link browser placement strategy.
    static var terminalLinkBrowserPlacementKey: String {
        SettingCatalog().browser.terminalLinkBrowserPlacement.userDefaultsKey
    }

    /// Placement used when no explicit user setting is stored.
    static var defaultTerminalLinkBrowserPlacement: TerminalLinkBrowserPlacement {
        SettingCatalog().browser.terminalLinkBrowserPlacement.defaultValue
    }

    /// Returns the configured terminal-link browser placement.
    static func terminalLinkBrowserPlacement(
        defaults: UserDefaults = .standard
    ) -> TerminalLinkBrowserPlacement {
        SettingCatalog().browser.terminalLinkBrowserPlacement.value(in: defaults)
    }
}
