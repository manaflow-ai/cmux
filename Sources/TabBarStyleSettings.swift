import Bonsplit
import Foundation

/// Reads the surface tab bar style overrides (issue #7458) from settings storage
/// and assembles a Bonsplit ``BonsplitConfiguration/Appearance/TabStyle``.
///
/// Mirrors the shape of ``PaneChromeSettings``: each override is an optional
/// top-level `tabBar*` key persisted in `UserDefaults` (and file-managed through
/// `cmux.json`). Every unset key leaves the corresponding Bonsplit-derived
/// styling untouched, so an all-empty configuration is a no-op.
enum TabBarStyleSettings {
    static let activeBackgroundKey = "tabBarActiveBackground"
    static let activeForegroundKey = "tabBarActiveForeground"
    static let inactiveBackgroundKey = "tabBarInactiveBackground"
    static let inactiveForegroundKey = "tabBarInactiveForeground"
    static let hoverBackgroundKey = "tabBarHoverBackground"
    static let dividerColorKey = "tabBarDividerColor"
    static let activeIndicatorColorKey = "tabBarActiveIndicatorColor"
    static let activeIndicatorEdgeKey = "tabBarActiveIndicatorEdge"
    static let fontFamilyKey = "tabBarFontFamily"
    static let fontWeightKey = "tabBarFontWeight"

    static let didChangeNotification = Notification.Name("cmux.tabBarStyleSettingsDidChange")

    /// The `cmux.json` / Settings-UI paths this reader owns, exposed so the file
    /// store allowlist can stay in sync.
    static let supportedKeys: [String] = [
        activeBackgroundKey,
        activeForegroundKey,
        inactiveBackgroundKey,
        inactiveForegroundKey,
        hoverBackgroundKey,
        dividerColorKey,
        activeIndicatorColorKey,
        activeIndicatorEdgeKey,
        fontFamilyKey,
        fontWeightKey,
    ]

    /// Builds the current tab-bar style overrides from persisted settings.
    static func tabStyle(defaults: UserDefaults = .standard) -> BonsplitConfiguration.Appearance.TabStyle {
        BonsplitConfiguration.Appearance.TabStyle(
            activeBackgroundHex: colorHex(activeBackgroundKey, defaults),
            activeForegroundHex: colorHex(activeForegroundKey, defaults),
            inactiveBackgroundHex: colorHex(inactiveBackgroundKey, defaults),
            inactiveForegroundHex: colorHex(inactiveForegroundKey, defaults),
            hoverBackgroundHex: colorHex(hoverBackgroundKey, defaults),
            dividerHex: dividerHex(defaults),
            activeIndicatorHex: colorHex(activeIndicatorColorKey, defaults),
            activeIndicatorEdge: indicatorEdge(defaults),
            fontFamily: nonEmptyString(fontFamilyKey, defaults),
            fontWeight: fontWeight(defaults)
        )
    }

    private static func colorHex(_ key: String, _ defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(raw)
    }

    /// The divider accepts the literal `"none"` sentinel (hide the divider) in
    /// addition to a normalized hex color.
    private static func dividerHex(_ defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: dividerColorKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        if raw.caseInsensitiveCompare("none") == .orderedSame { return "none" }
        return WorkspaceTabColorSettings.normalizedHex(raw)
    }

    private static func indicatorEdge(
        _ defaults: UserDefaults
    ) -> BonsplitConfiguration.Appearance.TabStyle.IndicatorEdge? {
        guard let raw = defaults.string(forKey: activeIndicatorEdgeKey)?.lowercased() else { return nil }
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        case "none", "hidden": return .hidden
        default: return nil
        }
    }

    private static func fontWeight(
        _ defaults: UserDefaults
    ) -> BonsplitConfiguration.Appearance.TabStyle.FontWeight? {
        guard let raw = defaults.string(forKey: fontWeightKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return BonsplitConfiguration.Appearance.TabStyle.FontWeight(rawValue: raw)
    }

    private static func nonEmptyString(_ key: String, _ defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
