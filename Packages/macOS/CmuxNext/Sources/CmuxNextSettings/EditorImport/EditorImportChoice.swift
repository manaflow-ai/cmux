/// `editor.importFrom`: which editor's settings give the code editor its defaults.
public nonisolated enum EditorImportChoice: Sendable, Hashable {
    /// The first editor in ``ImportableEditor/allCases`` order that has a settings file (the default).
    case auto
    /// No other editor: the code editor's own defaults.
    case none
    /// One editor.
    case editor(ImportableEditor)

    /// The choice `editor.importFrom` holds; an absent or unknown value is ``auto``
    /// (`import.editor_choice`).
    public init(setting: String?) {
        let reply = SettingsRust.answer("import.editor_choice", ["setting": setting.map(JSONValue.string) ?? .null])
        switch reply["choice"]?.stringValue {
        case "none"?: self = .none
        case let id?: self = ImportableEditor(rawValue: id).map(EditorImportChoice.editor) ?? .auto
        case nil: self = .auto
        }
    }

    /// The setting value Rust reads this choice from.
    var id: String {
        switch self {
        case .auto: "auto"
        case .none: "none"
        case .editor(let editor): editor.rawValue
        }
    }
}
