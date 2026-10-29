import CmuxNextAppearance
import Foundation

// SettingsSection is generated from schemas/settings/source/sections.json
// (SettingsSection.generated.swift, cx-d5b5d).

/// Localized text of the settings schema (Localizable.xcstrings in this module).
nonisolated enum SettingsText {
    /// `text` with its key, for schema texts that clients outside the app
    /// localize (`SettingsSchemaExport`).
    static func keyed(
        _ key: StaticString,
        _ value: String.LocalizationValue,
        strings: ModuleResourceBundle = .settings
    ) -> SettingText {
        SettingText(key: "\(key)", text: strings.text(key, defaultValue: value))
    }

    static func text(
        _ key: StaticString,
        _ value: String.LocalizationValue,
        strings: ModuleResourceBundle = .settings
    ) -> String {
        strings.text(key, defaultValue: value)
    }
}
