/// `editor.default` in cmux.json: the editor id (cmux-window-rules `editors`, `vscode`, `zed`...)
/// Open in Editor opens a chat's or workspace's folder in, and the agent pane's `file.open` with
/// `where: "editor"`. `auto` (the default) or an unset key is the first installed editor; the App
/// asks `window_editors_pick`, which also passes over a configured editor that is not installed.
/// `configPath`, `fallback` and `values` come from schemas/settings/source/browser.json
/// (SettingsSchema+Browser.generated.swift).
public nonisolated struct EditorDefaultSetting: Sendable, Hashable {
    /// The configured editor id; nil for the first installed one.
    public var editor: String?

    public init(editor: String? = nil) {
        self.editor = editor
    }

    static func parse(_ root: JSONValue) -> (EditorDefaultSetting, [SettingsDiagnostic]) {
        guard let value = root.value(at: configPath) else { return (EditorDefaultSetting(), []) }
        guard let text = value.stringValue, values.contains(text) else {
            let path = configPath.joined(separator: ".")
            return (EditorDefaultSetting(), [SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected one of \(values.joined(separator: ", "))")])
        }
        return (EditorDefaultSetting(editor: text == fallback ? nil : text), [])
    }
}
