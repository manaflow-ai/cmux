/// Controls the intentional Command/Control shortcut hint overlay.
public struct ModifierHoldHintsSetting: Sendable {
    /// The same key as classic cmux, enabled by default (path and default:
    /// schemas/settings/source/shortcut-hints.json, SettingsSchema+ShortcutHints.generated.swift).
    public let configPath = ModifierHoldHintsSetting.showModifierHoldHintsPath
    /// Shows hints when the configuration does not specify a preference.
    public let fallback = ModifierHoldHintsSetting.showModifierHoldHintsDefault

    /// Creates the modifier-hold preference parser with classic cmux defaults.
    public init() {}

    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "shortcuts.showModifierHoldHints", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
