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

    /// The catalog is the sole owner of file-editor keys, defaults, and
    /// validation bounds. This app-target facade keeps the existing call sites
    /// type-safe without duplicating any setting metadata.
    private static let catalog = FileEditorCatalogSection()

    /// Creates a settings reader backed by the supplied defaults store.
    ///
    /// - Parameter defaults: Defaults store used for runtime reads.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Catalog metadata used by runtime consumers that need a settings owner.
    /// Keeping this as an instance view makes it impossible for a defaults
    /// read to accidentally fall back to a process-wide static helper.
    var catalog: FileEditorCatalogSection { Self.catalog }

    static let syntaxHighlightingKey = catalog.syntaxHighlighting.userDefaultsKey
    static let lineNumbersKey = catalog.lineNumbers.userDefaultsKey
    static let indentGuidesKey = catalog.indentGuides.userDefaultsKey
    static let currentLineHighlightKey = catalog.currentLineHighlight.userDefaultsKey
    static let tabWidthKey = catalog.tabWidth.userDefaultsKey

    static let syntaxHighlightingDefault = catalog.syntaxHighlighting.defaultValue
    static let lineNumbersDefault = catalog.lineNumbers.defaultValue
    static let indentGuidesDefault = catalog.indentGuides.defaultValue
    static let currentLineHighlightDefault = catalog.currentLineHighlight.defaultValue
    static let tabWidthDefault = catalog.tabWidth.defaultValue
    static let tabWidthRange = catalog.tabWidthRange

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
