import CmuxSettings
import CmuxTerminalCore
import Foundation

/// App-owned access to cmux's managed adaptive terminal palette preference.
///
/// Ghostty's own `theme = light:X,dark:Y` setting remains independent and
/// appearance-adaptive. This setting only controls whether cmux supplies its
/// historical managed light/dark palette when the Ghostty config contains no
/// directives.
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
        load(
            preferredColorScheme: preferredColorScheme,
            useCache: useCache,
            globalFontMagnificationPercent: globalFontMagnificationPercent,
            adaptiveDefaultThemeEnabled:
                TerminalAdaptiveDefaultThemeSettings(defaults: defaults)
                    .isEnabled
        )
    }
}
