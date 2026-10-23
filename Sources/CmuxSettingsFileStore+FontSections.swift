import CmuxTerminalCore
import Foundation

/// Parses the cmux-owned font settings that historically lived in config.ghostty,
/// and the surface tab bar layout beside them. An invalid field keeps its last good
/// value while valid sibling settings from the same edit apply.
extension CmuxSettingsFileStore {
    func parseFontSections(
        _ root: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let sidebar = root["sidebar"] as? [String: Any] {
            if let value = jsonDouble(sidebar["fontSize"]), value.isFinite,
               (Double(GhosttyConfig.minSidebarFontSize)...Double(GhosttyConfig.maxSidebarFontSize)).contains(value) {
                snapshot.managedUserDefaults[CmuxJSONFontSettings.sidebarUserDefaultsKey] = .double(value)
            } else if sidebar.keys.contains("fontSize") {
                logInvalid(CmuxJSONFontSettings.sidebarPath, sourcePath: sourcePath)
                snapshot.invalidManagedUserDefaultKeys.insert(CmuxJSONFontSettings.sidebarUserDefaultsKey)
            }
        }
        if let tabBar = root["surfaceTabBar"] as? [String: Any] {
            if let value = jsonDouble(tabBar["fontSize"]), value.isFinite,
               (Double(GhosttyConfig.minSurfaceTabBarFontSize)...Double(GhosttyConfig.maxSurfaceTabBarFontSize)).contains(value) {
                snapshot.managedUserDefaults[CmuxJSONFontSettings.surfaceTabBarUserDefaultsKey] = .double(value)
            } else if tabBar.keys.contains("fontSize") {
                logInvalid(CmuxJSONFontSettings.surfaceTabBarPath, sourcePath: sourcePath)
                snapshot.invalidManagedUserDefaultKeys.insert(CmuxJSONFontSettings.surfaceTabBarUserDefaultsKey)
            }
            parseSurfaceTabBarLayout(tabBar, sourcePath: sourcePath, snapshot: &snapshot)
        }
    }

    /// Parses `surfaceTabBar.widthMode`, `.maxTabWidth` and `.height`.
    private func parseSurfaceTabBarLayout(
        _ tabBar: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        typealias Layout = SurfaceTabBarLayoutSettings
        if let raw = jsonString(tabBar["widthMode"]), let mode = Layout.WidthMode(rawValue: raw) {
            snapshot.managedUserDefaults[Layout.widthModeKey] = .string(mode.rawValue)
        } else if tabBar.keys.contains("widthMode") {
            logInvalid(Layout.widthModePath, sourcePath: sourcePath)
            snapshot.invalidManagedUserDefaultKeys.insert(Layout.widthModeKey)
        }
        let numericFields: [(jsonKey: String, path: String, defaultsKey: String, range: ClosedRange<CGFloat>)] = [
            ("maxTabWidth", Layout.maxTabWidthPath, Layout.maxTabWidthKey, Layout.maxTabWidthRange),
            ("height", Layout.heightPath, Layout.heightKey, Layout.heightRange),
        ]
        for field in numericFields {
            if let value = jsonDouble(tabBar[field.jsonKey]), value.isFinite,
               (Double(field.range.lowerBound)...Double(field.range.upperBound)).contains(value) {
                snapshot.managedUserDefaults[field.defaultsKey] = .double(value)
            } else if tabBar.keys.contains(field.jsonKey) {
                logInvalid(field.path, sourcePath: sourcePath)
                snapshot.invalidManagedUserDefaultKeys.insert(field.defaultsKey)
            }
        }
    }
}
