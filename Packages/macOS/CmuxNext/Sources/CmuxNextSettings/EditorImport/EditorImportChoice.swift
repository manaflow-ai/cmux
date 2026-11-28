/// `editor.importFrom`: which editor's settings give the code editor its defaults.
public nonisolated enum EditorImportChoice: Sendable, Hashable {
    /// The first editor in ``ImportableEditor/allCases`` order that has a settings file (the default).
    case auto
    /// No other editor: the code editor's own defaults.
    case none
    /// One editor.
    case editor(ImportableEditor)

    /// The choice `editor.importFrom` holds; an absent or unknown value is ``auto``.
    public init(setting: String?) {
        switch setting {
        case "none"?: self = .none
        case let name?: self = ImportableEditor(rawValue: name).map(EditorImportChoice.editor) ?? .auto
        case nil: self = .auto
        }
    }
}
