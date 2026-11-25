public import Foundation

/// Maps another editor's settings to the code editor's `editor` section (cmux.json keys, Monaco's
/// and VS Code's names): VS Code and the editors built on it (Cursor, Windsurf, VSCodium) read their
/// `settings.json` and `keybindings.json`; Zed its `settings.json` and `keymap.json`. Pure: it takes
/// parsed JSON and returns the section; ``EditorSettingsSources`` reads the files. The mapping lives
/// in Rust (cmux-config `editor_import`, the `import.editor_map` and `import.editor_section` ops).
///
/// ```swift
/// let section = EditorSettingsImport().vscode(settings: try JSONC.parse(text), keybindings: nil)
/// section["tabSize"] // .number(2)
/// ```
public nonisolated struct EditorSettingsImport: Sendable {
    public init() {}

    /// The `editor` section for a VS Code `settings.json` (parsed, comments stripped) and its
    /// `keybindings.json` (nil when the file is absent).
    public func vscode(settings: JSONValue, keybindings: JSONValue?) -> JSONValue {
        Self.map(.vscode, settings, keybindings)
    }

    /// The `editor` section for a Zed `settings.json` and its `keymap.json` (nil when absent).
    public func zed(settings: JSONValue, keymap: JSONValue?) -> JSONValue {
        Self.map(.zed, settings, keymap)
    }

    static func map(_ editor: ImportableEditor, _ settings: JSONValue, _ keys: JSONValue?) -> JSONValue {
        let request: JSONValue = ["editor": .string(editor.rawValue), "settings": settings, "keys": keys ?? .null]
        return SettingsRust.answer("import.editor_map", request)["section"] ?? .object([:])
    }

    /// The code editor's section: `imported` under `own` (a key set in cmux.json wins, objects
    /// merged member by member).
    public static func section(imported: JSONValue, own: JSONValue) -> JSONValue {
        SettingsRust.answer("import.editor_section", ["imported": imported, "own": own])["section"] ?? .object([:])
    }
}
