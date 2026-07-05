import Foundation

/// Persistent toggle for syntax highlighting in the built-in plain-text file
/// preview/editor.
///
/// Backed by the `fileEditor.syntaxHighlighting` key, shared by the Settings
/// window (`CmuxSettings` catalog), the `~/.config/cmux/cmux.json` parser, and
/// the `FilePreviewTextEditor`. `true` (the default) colorizes recognized source
/// files; `false` restores plain, uncolored text. Changing this applies live to
/// open editors.
enum FilePreviewSyntaxHighlightSettings {
    /// UserDefaults / cmux.json key.
    static let key = "fileEditor.syntaxHighlighting"

    /// Default state: highlighting on.
    static let defaultEnabled = true

    /// Whether syntax highlighting is currently enabled, honoring the stored
    /// override and falling back to ``defaultEnabled``.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultEnabled : defaults.bool(forKey: key)
    }
}
