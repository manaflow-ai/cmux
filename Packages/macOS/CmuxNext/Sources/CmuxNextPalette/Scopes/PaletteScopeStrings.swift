import Foundation

/// Strings of palette scopes. Keys live in the module's Localizable.xcstrings.
nonisolated extension PaletteStrings {
    static var scopesTitle: String { String(localized: "palette.scope.scopes.title", defaultValue: "Scopes", bundle: .module) }
    static var scopesPlaceholder: String {
        String(localized: "palette.scope.scopes.placeholder", defaultValue: "Search scopes…", bundle: .module)
    }
    static var sectionScopes: String { String(localized: "palette.section.scopes", defaultValue: "Search In", bundle: .module) }
    static var allScopes: String { String(localized: "palette.scope.all", defaultValue: "All Scopes", bundle: .module) }

    static func scopeHintPrefixKeyword(_ prefix: String, _ keyword: String) -> String {
        String(localized: "palette.scope.hint.prefixKeyword", defaultValue: "Type \(prefix), or \(keyword) and Tab", bundle: .module)
    }
    static func scopeHintPrefix(_ prefix: String) -> String {
        String(localized: "palette.scope.hint.prefix", defaultValue: "Type \(prefix)", bundle: .module)
    }
    static func scopeHintKeyword(_ keyword: String) -> String {
        String(localized: "palette.scope.hint.keyword", defaultValue: "Type \(keyword) and Tab", bundle: .module)
    }
    /// Right of the field when the query is a scope's keyword.
    static func keywordHint(_ title: String) -> String {
        String(localized: "palette.scope.keywordHint", defaultValue: "Search \(title)", bundle: .module)
    }
    /// VoiceOver label of a chip.
    static func chipAccessibility(_ title: String) -> String {
        String(localized: "palette.scope.chip.accessibility", defaultValue: "\(title) scope. Press Delete to leave.", bundle: .module)
    }
    /// Tooltip of a chip below the top one.
    static func backTo(_ title: String) -> String {
        String(localized: "palette.scope.backTo", defaultValue: "Back to \(title)", bundle: .module)
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
                   defaultValue: "A palette scope opens only when focus is requested; read rows with palette.query", bundle: .module)
        case .unknownScope(let id):
            String(localized: "palette.scope.refusal.unknown", defaultValue: "No palette scope \(id)", bundle: .module)
        }
    }
}
