import Foundation

// The trailing toolbar buttons (BrowserToolbarButtonsView).
nonisolated extension Strings {
    static func toolbarZoom(_ percent: Int) -> String {
        String(localized: "browser.toolbar.zoom", defaultValue: "Zoom \(percent)%: Reset to Actual Size", bundle: .localizedModule)
    }
    static var toolbarPublish: String {
        String(localized: "browser.toolbar.publish", defaultValue: "Publish", bundle: .localizedModule)
    }
    static var toolbarMedia: String {
        String(localized: "browser.toolbar.media", defaultValue: "Media Controls", bundle: .localizedModule)
    }
    static var toolbarDownloads: String {
        String(localized: "browser.toolbar.downloads", defaultValue: "Downloads", bundle: .localizedModule)
    }
    static var toolbarFavorites: String {
        String(localized: "browser.toolbar.favorites", defaultValue: "Bookmarks", bundle: .localizedModule)
    }
    static var toolbarDesignMode: String {
        String(localized: "browser.toolbar.designMode", defaultValue: "Design Mode", bundle: .localizedModule)
    }
    static func toolbarProfile(_ name: String) -> String {
        String(localized: "browser.toolbar.profile", defaultValue: "Browser Profile: \(name)", bundle: .localizedModule)
    }
    static var toolbarProfileUnknown: String {
        String(localized: "browser.toolbar.profileUnknown", defaultValue: "Browser Profile", bundle: .localizedModule)
    }
    static func toolbarTheme(_ scheme: BrowserColorScheme) -> String {
        let name = switch scheme {
        case .system: String(localized: "browser.toolbar.theme.system", defaultValue: "System", bundle: .localizedModule)
        case .light: String(localized: "browser.toolbar.theme.light", defaultValue: "Light", bundle: .localizedModule)
        case .dark: String(localized: "browser.toolbar.theme.dark", defaultValue: "Dark", bundle: .localizedModule)
        }
        return String(localized: "browser.toolbar.theme", defaultValue: "Browser Theme: \(name)", bundle: .localizedModule)
    }
    static var toolbarDevTools: String {
        String(localized: "browser.toolbar.devTools", defaultValue: "Toggle Developer Tools", bundle: .localizedModule)
    }
    static var toolbarDevToolsNeedsChromium: String {
        String(localized: "browser.toolbar.devTools.needsChromium",
               defaultValue: "Developer Tools need this tab's Chromium page to be running", bundle: .localizedModule)
    }
    static var toolbarDevToolsUnavailable: String {
        String(localized: "browser.toolbar.devTools.unavailable",
               defaultValue: "Developer Tools are not available for this page", bundle: .localizedModule)
    }
    static var toolbarMore: String {
        String(localized: "browser.toolbar.more", defaultValue: "More Actions", bundle: .localizedModule)
    }
    // The More menu's Show in Toolbar submenu (cx-d0d.81).
    static var toolbarShowInToolbar: String {
        String(localized: "browser.toolbar.showInToolbar", defaultValue: "Show in Toolbar", bundle: .localizedModule)
    }
    // The More menu's zoom row (GlassMenuStepperItem).
    static var toolbarMenuZoom: String {
        String(localized: "browser.toolbar.menu.zoom", defaultValue: "Zoom", bundle: .localizedModule)
    }
    static var toolbarPinZoom: String {
        String(localized: "browser.toolbar.pin.zoom", defaultValue: "Zoom Level", bundle: .localizedModule)
    }
    static var toolbarPinTheme: String {
        String(localized: "browser.toolbar.pin.theme", defaultValue: "Browser Theme", bundle: .localizedModule)
    }
    static var toolbarPinDevTools: String {
        String(localized: "browser.toolbar.pin.devTools", defaultValue: "Developer Tools", bundle: .localizedModule)
    }
}
