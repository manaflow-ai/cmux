import CmuxSettings
import Foundation

/// Persistent toggle for soft line wrapping in the plain-text file editor.
///
/// Backed by the `fileEditor.wordWrap` key, shared by the Settings window
/// (`CmuxSettings` catalog), the `~/.config/cmux/cmux.json` parser, and the
/// `FilePreviewTextEditor`. `false` preserves the established no-wrap behavior
/// (long lines extend past the viewport with a horizontal scroller).
enum FilePreviewWordWrapSettings {
    private static let catalog = FileEditorCatalogSection()

    /// UserDefaults / cmux.json key.
    static var key: String { catalog.wordWrap.userDefaultsKey }

    /// Default state: wrapping off, matching the editor's prior behavior.
    static var defaultEnabled: Bool { catalog.wordWrap.defaultValue }

    /// Whether word wrap is currently enabled, honoring the stored override
    /// and falling back to ``defaultEnabled``.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultEnabled : defaults.bool(forKey: key)
    }
}
