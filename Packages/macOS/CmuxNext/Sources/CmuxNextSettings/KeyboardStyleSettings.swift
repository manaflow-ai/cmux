// The paths, defaults and the choice enums (KeyStyleSetting, ShortcutLayoutSetting) are generated
// from schemas/settings/source/keyboard-style.json (Schema/SettingsSchema+KeyboardStyle*.generated.swift);
// this file only parses. What each choice does lives in Rust (cmux-tui/crates/cmux-keymap) and its
// web twin (webviews/src/ui/keyStyle.ts), from schemas/keymap/key-styles.json.

/// `app.keyStyle` and `app.shortcutLayout` in cmux.json (design/keyboard-style.md): the keys
/// lists answer to, and whether shortcuts follow the keyboard layout or the US key positions.
/// Both default to today's behavior.
public nonisolated struct KeyboardStyleSettings: Sendable, Equatable {
    /// Standard, Vim or Emacs list keys.
    public var keyStyle = KeyboardStyleSettings.keyStyleDefault
    /// Follow the layout's characters, or keep QWERTY positions.
    public var shortcutLayout = KeyboardStyleSettings.shortcutLayoutDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["app"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("keyStyle", KeyStyleSetting.self) { settings.keyStyle = value }
        if let value = reader.choice("shortcutLayout", ShortcutLayoutSetting.self) { settings.shortcutLayout = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
