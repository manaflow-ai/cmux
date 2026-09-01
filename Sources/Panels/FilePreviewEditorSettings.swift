import Foundation

/// Persistent File Preview code-view chrome settings.
///
/// Keys live under `fileEditor.*` and are shared by the Settings catalog,
/// `~/.config/cmux/cmux.json`, and the text editor. Defaults match VS Code /
/// Cursor / Zed: highlighting, line numbers, indent guides, and current-line
/// highlight are on.
struct FilePreviewEditorSettings {
    let defaults: UserDefaults

    /// Creates a settings reader backed by the supplied defaults store.
    ///
    /// - Parameter defaults: Defaults store used for runtime reads.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static let syntaxHighlightingKey = "fileEditor.syntaxHighlighting"
    static let lineNumbersKey = "fileEditor.lineNumbers"
    static let indentGuidesKey = "fileEditor.indentGuides"
    static let currentLineHighlightKey = "fileEditor.currentLineHighlight"
    static let tabWidthKey = "fileEditor.tabWidth"

    static let syntaxHighlightingDefault = true
    static let lineNumbersDefault = true
    static let indentGuidesDefault = true
    static let currentLineHighlightDefault = true
    static let tabWidthDefault = 4
    static let tabWidthRange = 1...8

    func isEnabled(
        key: String,
        default defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    var tabWidth: Int {
        let stored = defaults.object(forKey: Self.tabWidthKey) as? Int ?? Self.tabWidthDefault
        return min(max(stored, Self.tabWidthRange.lowerBound), Self.tabWidthRange.upperBound)
    }
}
