import Foundation

/// User-defined cmux chrome colors and SF Symbol substitutions.
///
/// Values are stored as JSON strings in UserDefaults so the app can observe the
/// complete map through one `@AppStorage` value while cmux.json exposes them as
/// normal dictionaries under `appearance.colors` and `appearance.icons`.
public struct InterfaceAppearanceCatalogSection: SettingCatalogSection {
    public let colorsJSON = DefaultsKey<String>(
        id: "appearance.colors",
        defaultValue: "{}",
        userDefaultsKey: "interfaceAppearanceColorsJSON"
    )

    public let iconsJSON = DefaultsKey<String>(
        id: "appearance.icons",
        defaultValue: "{}",
        userDefaultsKey: "interfaceAppearanceIconsJSON"
    )

    public init() {}
}
