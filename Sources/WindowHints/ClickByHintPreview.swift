import CmuxSettings
import Foundation

/// Click by Hint as a preview: hint mode (``WindowHintController``) stays
/// off by default, and the Beta Features toggle turns it on for one person
/// (Settings, the command palette, or `windowHints.beta.enabled` in
/// cmux.json). The remote rollout flag (`FeatureFlags`) can still turn it on
/// for everyone.
enum ClickByHintPreview {
    static let commandId = "palette.toggleSetting.windowHints"

    nonisolated static func isOptedIn(defaults: UserDefaults = .standard) -> Bool {
        let key = BetaFeaturesCatalogSection().windowHints
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    static let paletteToggle = CommandPaletteSettingToggleDescriptor(
        commandId: commandId,
        settingsKey: "betaFeatures.clickByHint",
        title: { String(localized: "settings.betaFeatures.clickByHint", defaultValue: "Click by Hint") },
        sectionTitle: { String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features") },
        keywords: ["windowHints.beta.enabled", "click", "hint", "hints", "label", "keyboard", "vimium", "preview", "beta"],
        defaultValue: BetaFeaturesCatalogSection().windowHints.defaultValue,
        defaultsKey: BetaFeaturesCatalogSection().windowHints.userDefaultsKey
    )
}
