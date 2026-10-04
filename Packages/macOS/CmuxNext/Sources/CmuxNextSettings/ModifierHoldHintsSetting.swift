/// Controls the intentional Command/Control shortcut hint overlay.
public struct ModifierHoldHintsSetting: Sendable {
    /// The same key as classic cmux, enabled by default.
    public static let configPath = ["shortcuts", "showModifierHoldHints"]
    public static let fallback = true

    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "shortcuts.showModifierHoldHints", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
