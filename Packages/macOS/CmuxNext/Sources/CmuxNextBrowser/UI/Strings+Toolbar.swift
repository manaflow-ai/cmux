import Foundation

// The trailing toolbar buttons (BrowserToolbarButtonsView).
nonisolated extension Strings {
    static var toolbarDesignMode: String {
        String(localized: "browser.toolbar.designMode", defaultValue: "Design Mode", bundle: .module)
    }
    static func toolbarProfile(_ name: String) -> String {
        String(localized: "browser.toolbar.profile", defaultValue: "Browser Profile: \(name)", bundle: .module)
    }
    static var toolbarProfileUnknown: String {
        String(localized: "browser.toolbar.profileUnknown", defaultValue: "Browser Profile", bundle: .module)
    }
    static func toolbarTheme(_ scheme: BrowserColorScheme) -> String {
        let name = switch scheme {
        case .system: String(localized: "browser.toolbar.theme.system", defaultValue: "System", bundle: .module)
        case .light: String(localized: "browser.toolbar.theme.light", defaultValue: "Light", bundle: .module)
        case .dark: String(localized: "browser.toolbar.theme.dark", defaultValue: "Dark", bundle: .module)
        }
        return String(localized: "browser.toolbar.theme", defaultValue: "Browser Theme: \(name)", bundle: .module)
    }
    static var toolbarDevTools: String {
        String(localized: "browser.toolbar.devTools", defaultValue: "Toggle Developer Tools", bundle: .module)
    }
    static var toolbarDevToolsNeedsChromium: String {
        String(localized: "browser.toolbar.devTools.needsChromium",
               defaultValue: "Developer Tools need this tab's Chromium page to be running", bundle: .module)
    }
    static var toolbarDevToolsUnavailable: String {
        String(localized: "browser.toolbar.devTools.unavailable",
               defaultValue: "Developer Tools are not available for this page", bundle: .module)
    }
    static var toolbarMore: String {
        String(localized: "browser.toolbar.more", defaultValue: "More Actions", bundle: .module)
    }
}
