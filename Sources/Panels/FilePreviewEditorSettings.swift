import CmuxSettings
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

    static let syntaxHighlightingKey = FileEditorCatalogSection().syntaxHighlighting.userDefaultsKey
    static let lineNumbersKey = FileEditorCatalogSection().lineNumbers.userDefaultsKey
    static let indentGuidesKey = FileEditorCatalogSection().indentGuides.userDefaultsKey
    static let currentLineHighlightKey = FileEditorCatalogSection().currentLineHighlight.userDefaultsKey
    static let tabWidthKey = FileEditorCatalogSection().tabWidth.userDefaultsKey

    static let syntaxHighlightingDefault = FileEditorCatalogSection().syntaxHighlighting.defaultValue
    static let lineNumbersDefault = FileEditorCatalogSection().lineNumbers.defaultValue
    static let indentGuidesDefault = FileEditorCatalogSection().indentGuides.defaultValue
    static let currentLineHighlightDefault = FileEditorCatalogSection().currentLineHighlight.defaultValue
    static let tabWidthDefault = FileEditorCatalogSection().tabWidth.defaultValue
    static let tabWidthRange = FileEditorCatalogSection().tabWidthRange

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
