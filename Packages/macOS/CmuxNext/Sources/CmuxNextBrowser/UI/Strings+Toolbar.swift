import Foundation

// The trailing toolbar buttons (BrowserToolbarButtonsView).
nonisolated extension Strings {
    static func toolbarZoom(_ percent: Int) -> String {
        String(localized: "browser.toolbar.zoom", defaultValue: "Zoom \(percent)%: Reset to Actual Size", bundle: .l10n)
    }
    static var toolbarMedia: String {
        String(localized: "browser.toolbar.media", defaultValue: "Media Controls", bundle: .l10n)
    }
    static var toolbarDownloads: String {
        String(localized: "browser.toolbar.downloads", defaultValue: "Downloads", bundle: .l10n)
    }
    static var toolbarFavorites: String {
        String(localized: "browser.toolbar.favorites", defaultValue: "Bookmarks", bundle: .l10n)
    }
    static var toolbarDesignMode: String {
        String(localized: "browser.toolbar.designMode", defaultValue: "Design Mode", bundle: .l10n)
    }
    static func toolbarProfile(_ name: String) -> String {
        String(localized: "browser.toolbar.profile", defaultValue: "Browser Profile: \(name)", bundle: .l10n)
    }
    static var toolbarProfileUnknown: String {
        String(localized: "browser.toolbar.profileUnknown", defaultValue: "Browser Profile", bundle: .l10n)
    }
    static func toolbarTheme(_ scheme: BrowserColorScheme) -> String {
        let name = switch scheme {
        case .system: String(localized: "browser.toolbar.theme.system", defaultValue: "System", bundle: .l10n)
        case .light: String(localized: "browser.toolbar.theme.light", defaultValue: "Light", bundle: .l10n)
        case .dark: String(localized: "browser.toolbar.theme.dark", defaultValue: "Dark", bundle: .l10n)
        }
        return String(localized: "browser.toolbar.theme", defaultValue: "Browser Theme: \(name)", bundle: .l10n)
    }
    static var toolbarDevTools: String {
        String(localized: "browser.toolbar.devTools", defaultValue: "Toggle Developer Tools", bundle: .l10n)
    }
    static var toolbarDevToolsNeedsChromium: String {
        String(localized: "browser.toolbar.devTools.needsChromium",
               defaultValue: "Developer Tools need this tab's Chromium page to be running", bundle: .l10n)
    }
    static var toolbarDevToolsUnavailable: String {
        String(localized: "browser.toolbar.devTools.unavailable",
               defaultValue: "Developer Tools are not available for this page", bundle: .l10n)
    }
    static var toolbarMore: String {
        String(localized: "browser.toolbar.more", defaultValue: "More Actions", bundle: .l10n)
    }
    // The More menu's Show in Toolbar submenu (cx-d0d.81).
    static var toolbarShowInToolbar: String {
        String(localized: "browser.toolbar.showInToolbar", defaultValue: "Show in Toolbar", bundle: .l10n)
    }
    static var toolbarPinZoom: String {
        String(localized: "browser.toolbar.pin.zoom", defaultValue: "Zoom Level", bundle: .l10n)
    }
    static var toolbarPinTheme: String {
        String(localized: "browser.toolbar.pin.theme", defaultValue: "Browser Theme", bundle: .l10n)
    }
    static var toolbarPinDevTools: String {
        String(localized: "browser.toolbar.pin.devTools", defaultValue: "Developer Tools", bundle: .l10n)
    }
}
