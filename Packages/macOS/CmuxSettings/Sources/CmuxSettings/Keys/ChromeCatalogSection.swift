import Foundation

/// Settings for cmux-owned application chrome.
///
/// Both values live in `cmux.json` so a theme can be shared across machines,
/// versioned with dotfiles, and edited by the CLI/config editor without a
/// second UserDefaults source of truth.
public struct ChromeCatalogSection: SettingCatalogSection {
    /// Selected built-in chrome theme. The existing `app.appearance` setting
    /// still controls light/dark selection for the chosen theme.
    public let theme = JSONKey<ChromeThemeID>(
        id: "chrome.theme",
        defaultValue: .default
    )

    /// Flat token-to-hex overrides layered over the selected theme.
    public let overrides = JSONKey<ChromeTokenOverrides>(
        id: "chrome.overrides",
        defaultValue: .empty
    )

    /// Creates the chrome settings declarations.
    public init() {}
}
