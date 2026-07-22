import Foundation

/// Persistent toggle for soft line wrapping in the plain-text file editor.
///
/// Backed by the `fileEditor.wordWrap` key, shared by the Settings window
/// (`CmuxSettings` catalog), the `~/.config/cmux/cmux.json` parser, and the
/// `FilePreviewTextEditor`. `false` preserves the established no-wrap behavior
/// (long lines extend past the viewport with a horizontal scroller).
enum FilePreviewWordWrapSettings {
    /// UserDefaults / cmux.json key.
    static let key = "fileEditor.wordWrap"

    /// Default state: wrapping off, matching the editor's prior behavior.
    static let defaultEnabled = false

    /// Whether word wrap is currently enabled, honoring the stored override
    /// and falling back to ``defaultEnabled``.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultEnabled : defaults.bool(forKey: key)
    }
}

/// Which renderer draws the text mode of File Preview panels.
///
/// Backed by the `fileEditor.engine` key, shared by the Settings window
/// (`CmuxSettings` catalog) and the `~/.config/cmux/cmux.json` parser.
/// `"plain"` (the default) is the established NSTextView editor; `"code"`
/// renders the CodeMirror-based code editor webview with syntax highlighting.
enum FilePreviewEditorEngineSettings {
    /// UserDefaults / cmux.json key.
    static let key = "fileEditor.engine"

    static let plainEngine = "plain"
    static let codeEngine = "code"

    /// Default engine: the plain NSTextView editor, matching prior behavior.
    static let defaultEngine = plainEngine

    static let validEngines: Set<String> = [plainEngine, codeEngine]

    static func isCodeEngineEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == codeEngine
    }
}
