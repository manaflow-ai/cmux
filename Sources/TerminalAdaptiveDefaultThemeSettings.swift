import CmuxSettings
import CmuxTerminalCore
import Foundation

/// App-owned access to cmux's managed adaptive terminal palette preference.
///
/// Ghostty's own `theme = light:X,dark:Y` setting remains independent and
/// appearance-adaptive. This setting only controls whether cmux supplies its
/// managed light/dark palette when the Ghostty config contains no authored
/// theme or terminal colors. Non-color settings preserve the adaptive base.
struct TerminalAdaptiveDefaultThemeSettings {
    private static let key = SettingCatalog().terminal.adaptiveDefaultTheme

    static let didChangeNotification = Notification.Name(
        "cmux.terminalAdaptiveDefaultThemeSettingsDidChange"
    )

    static var userDefaultsKey: String { key.userDefaultsKey }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.userDefaultsKey) as? Bool
            ?? Self.key.defaultValue
    }

    static func notifyDidChange(
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

extension GhosttyConfig {
    /// Loads the resolved Ghostty config with cmux's adaptive-default
    /// preference. App code uses this wrapper so every config consumer shares
    /// the same setting, while `CmuxTerminalCore` remains settings-independent.
    static func loadForCmux(
        preferredColorScheme: ColorSchemePreference? = nil,
        useCache: Bool = true,
        globalFontMagnificationPercent: Int? = nil,
        defaults: UserDefaults = .standard
    ) -> GhosttyConfig {
        var loaded = load(
            preferredColorScheme: preferredColorScheme,
            useCache: useCache,
            globalFontMagnificationPercent: globalFontMagnificationPercent,
            adaptiveDefaultThemeEnabled:
                TerminalAdaptiveDefaultThemeSettings(defaults: defaults)
                    .isEnabled
        )
        if let value = defaults.object(forKey: CmuxJSONFontSettings.sidebarUserDefaultsKey) as? NSNumber {
            loaded.sidebarFontSize = Self.clampedSidebarFontSize(value.doubleValue)
        }
        if let value = defaults.object(forKey: CmuxJSONFontSettings.surfaceTabBarUserDefaultsKey) as? NSNumber {
            loaded.surfaceTabBarFontSize = Self.clampedSurfaceTabBarFontSize(value.doubleValue)
        }
        return loaded
    }
}

private extension GhosttyConfig {
    static func clampedSidebarFontSize(_ value: Double) -> CGFloat {
        min(max(CGFloat(value), minSidebarFontSize), maxSidebarFontSize)
    }

    static func clampedSurfaceTabBarFontSize(_ value: Double) -> CGFloat {
        min(max(CGFloat(value), minSurfaceTabBarFontSize), maxSurfaceTabBarFontSize)
    }
}
