/// `shortcuts.keyPositions` in cmux.json: which key a Command or Control
/// shortcut means. `"typed"` (the default) is the letter the selected layout
/// types; `"qwerty"` is the key's US QWERTY position, as macOS's
/// "Dvorak - QWERTY Command" layout, so a Dvorak or Colemak typist keeps
/// Cmd-C, Cmd-V and Cmd-T where a US keyboard has them. `configPath`,
/// `fallback` and `values` come from schemas/settings/source/shortcut-hints.json
/// (SettingsSchema+ShortcutHints.generated.swift).
public nonisolated struct ShortcutKeyPositionsSetting: Sendable {
    /// Creates the `shortcuts.keyPositions` parser.
    public init() {}

    /// Whether `value` asks for QWERTY positions. Absent is `"typed"`; any
    /// other value is `"typed"` plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: Self.configPath) else { return (Self.fallback == "qwerty", nil) }
        guard let text = value.stringValue, Self.values.contains(text) else {
            return (Self.fallback == "qwerty", SettingsDiagnostic(
                kind: .invalidValue, path: "shortcuts.keyPositions", message: "expected \"typed\" or \"qwerty\""
            ))
        }
        return (text == "qwerty", nil)
    }
}
