import Foundation

/// Persistent File Preview code-view chrome settings.
///
/// Keys live under `fileEditor.*` and are shared by the Settings catalog,
/// `~/.config/cmux/cmux.json`, and the text editor. Defaults match VS Code /
/// Cursor / Zed: highlighting, line numbers, indent guides, and current-line
/// highlight are on.
enum FilePreviewEditorSettings {
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

    static func isEnabled(
        key: String,
        default defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func tabWidth(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: tabWidthKey) as? Int ?? tabWidthDefault
        return min(max(stored, tabWidthRange.lowerBound), tabWidthRange.upperBound)
    }
}
