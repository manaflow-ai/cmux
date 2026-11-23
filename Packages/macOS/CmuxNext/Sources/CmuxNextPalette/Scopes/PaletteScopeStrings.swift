import Foundation

/// Strings of palette scopes. Keys live in the module's Localizable.xcstrings.
nonisolated extension PaletteStrings {
    static var scopesTitle: String { String(localized: "palette.scope.scopes.title", defaultValue: "Scopes", bundle: .localizedModule) }
    static var scopesPlaceholder: String {
        String(localized: "palette.scope.scopes.placeholder", defaultValue: "Search scopes…", bundle: .localizedModule)
    }
    static var sectionScopes: String { String(localized: "palette.section.scopes", defaultValue: "Search In", bundle: .localizedModule) }
    static var allScopes: String { String(localized: "palette.scope.all", defaultValue: "All Scopes", bundle: .localizedModule) }

    static func scopeHintKeyword(_ keyword: String) -> String {
        String(localized: "palette.scope.hint.keyword", defaultValue: "Type \(keyword) and Tab", bundle: .localizedModule)
    }
    /// Right of the field when the query is a scope's keyword.
    static func keywordHint(_ title: String) -> String {
        String(localized: "palette.scope.keywordHint", defaultValue: "Search \(title)", bundle: .localizedModule)
    }
    /// VoiceOver label of a chip.
    static func chipAccessibility(_ title: String) -> String {
        String(localized: "palette.scope.chip.accessibility", defaultValue: "\(title) scope. Press Delete to leave.", bundle: .localizedModule)
    }
    /// Tooltip of a chip below the top one.
    static func backTo(_ title: String) -> String {
        String(localized: "palette.scope.backTo", defaultValue: "Back to \(title)", bundle: .localizedModule)
    }
}

/// Why `palette.open` refused, with the text the App reports.
public nonisolated enum PaletteOpenRefusal: Error, Sendable, Equatable {
    /// A CLI or MCP run without `focus: true` (the palette takes the keyboard).
    case needsFocus
    /// The scope id is not in the scope graph.
    case unknownScope(String)

    public var message: String {
        switch self {
        case .needsFocus:
            String(localized: "palette.scope.refusal.needsFocus",
                   defaultValue: "A palette scope opens only when focus is requested; read rows with palette.query", bundle: .localizedModule)
        case .unknownScope(let id):
            String(localized: "palette.scope.refusal.unknown", defaultValue: "No palette scope \(id)", bundle: .localizedModule)
        }
    }
}

/// Why `palette.run` refused a row (palette-scopes.md 6.10), with the
/// control error code the CLI maps to its exit code.
public nonisolated enum PaletteRunRefusal: Error, Sendable, Equatable {
    case unknownItem(scope: String, item: String)
    /// The row has no typed action (only its palette closures run it).
    case untyped(title: String)
    case unknownAction(item: String, action: String)

    public var code: String {
        switch self {
        case .unknownItem: "palette.item_unknown"
        case .untyped: "palette.row_untyped"
        case .unknownAction: "palette.action_unknown"
        }
    }

    public var message: String {
        switch self {
        case .unknownItem(let scope, let item):
            String(localized: "palette.run.refusal.noItem", defaultValue: "No row \(item) in palette scope \(scope)", bundle: .localizedModule)
        case .untyped(let title):
            String(localized: "palette.run.refusal.untyped", defaultValue: "The row \(title) has no typed action; it runs only in the palette", bundle: .localizedModule)
        case .unknownAction(let item, let action):
            String(localized: "palette.run.refusal.noAction", defaultValue: "The row \(item) has no action \(action)", bundle: .localizedModule)
        }
    }
}
