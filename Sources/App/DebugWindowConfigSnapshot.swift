import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum DebugWindowConfigSnapshot {
    static func copyCombinedToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combinedPayload(defaults: defaults), forType: .string)
    }

    static func combinedPayload(defaults: UserDefaults = .standard) -> String {
        let sidebarPayload = """
        sidebarPreset=\(stringValue(defaults, key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(stringValue(defaults, key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(stringValue(defaults, key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(stringValue(defaults, key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(stringValue(defaults, key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(stringValue(defaults, key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(stringValue(defaults, key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", doubleValue(defaults, key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarBranchVerticalLayout=\(boolValue(defaults, key: SidebarBranchLayoutSettings.key, fallback: SidebarBranchLayoutSettings.defaultVerticalLayout))
        sidebarBranchDirectoryStacked=\(boolValue(defaults, key: SidebarBranchDirectoryStackedSettings.key, fallback: SidebarBranchDirectoryStackedSettings.defaultStacked))
        sidebarPathLastSegmentOnly=\(boolValue(defaults, key: SidebarPathLastSegmentSettings.key, fallback: SidebarPathLastSegmentSettings.defaultLastSegmentOnly))
        sidebarActiveTabIndicatorStyle=\(stringValue(defaults, key: SidebarActiveTabIndicatorSettings.styleKey, fallback: SidebarActiveTabIndicatorSettings.defaultStyle.rawValue))
        sidebarDevBuildBannerVisible=\(boolValue(defaults, key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        sidebarMinimumWidth=\(String(format: "%.1f", SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(boolValue(defaults, key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(stringValue(defaults, key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(stringValue(defaults, key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "bgGlassTintOpacity", fallback: 0.03)))
        """

        let menuBarPayload = MenuBarIconDebugSettings.copyPayload(defaults: defaults)
        let browserDevToolsPayload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        let titlebarLayoutPayload = TitlebarLayoutDebugSettingsSnapshot.copyPayload(defaults: defaults)

        return """
        # Sidebar Debug
        \(sidebarPayload)

        # Titlebar Layout Debug
        \(titlebarLayoutPayload)

        # Background Debug
        \(backgroundPayload)

        # Menu Bar Extra Debug
        \(menuBarPayload)

        # Browser DevTools Button
        \(browserDevToolsPayload)
        """
    }

    private static func stringValue(_ defaults: UserDefaults, key: String, fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func doubleValue(_ defaults: UserDefaults, key: String, fallback: Double) -> Double {
        if let value = defaults.object(forKey: key) as? NSNumber {
            return value.doubleValue
        }
        if let text = defaults.string(forKey: key), let parsed = Double(text) {
            return parsed
        }
        return fallback
    }

    private static func boolValue(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
