import CmuxSettings
import Foundation

/// Fuzzy-match index over ``SettingsSectionID`` titles and keywords.
///
/// The index is precomputed at construction so per-keystroke filtering
/// is O(sections + n_settings). Diacritic-insensitive matching is via
/// `String.folding(options:locale:)`.
public struct SettingsSearchIndex: Sendable {
    /// A single searchable entry — either a section or a leaf setting
    /// (derived from the catalog's `AnySettingKey`).
    public struct Entry: Sendable, Identifiable, Hashable {
        public enum Kind: Sendable, Hashable {
            case section
            case setting(parent: SettingsSectionID)
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let symbolName: String
        public let normalizedSearchText: String
    }

    public let entries: [Entry]

    /// Builds an index from the section enum and the catalog's flat key
    /// list. Each setting's dotted id is split to infer which section it
    /// belongs to.
    public init(catalog: SettingCatalog) {
        var built: [Entry] = []
        for section in SettingsSectionID.allCases {
            built.append(Entry(
                id: "section:\(section.rawValue)",
                kind: .section,
                title: section.title,
                symbolName: section.symbolName,
                normalizedSearchText: Self.normalize(
                    "\(section.title) \(section.searchKeywords)"
                )
            ))
        }
        for key in catalog.all {
            let parent = Self.inferParent(fromKeyID: key.id) ?? .app
            built.append(Entry(
                id: "setting:\(key.id)",
                kind: .setting(parent: parent),
                title: key.id,
                symbolName: parent.symbolName,
                normalizedSearchText: Self.normalize(key.id)
            ))
        }
        self.entries = built
    }

    /// Returns the entries that match every token in ``query``. An empty
    /// query returns all section entries (the default sidebar view).
    public func match(_ query: String) -> [Entry] {
        let tokens = Self.tokens(in: query)
        if tokens.isEmpty {
            return entries.filter { if case .section = $0.kind { return true } else { return false } }
        }
        return entries.filter { entry in
            tokens.allSatisfy { entry.normalizedSearchText.contains($0) }
        }
    }

    // MARK: - Private

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func tokens(in query: String) -> [String] {
        normalize(query)
            .split { character in
                character.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                }
            }
            .map(String.init)
    }

    private static func inferParent(fromKeyID id: String) -> SettingsSectionID? {
        guard let prefix = id.split(separator: ".").first else { return nil }
        switch String(prefix) {
        case "app": return .app
        case "terminal": return .terminal
        case "sidebar", "sidebarAppearance": return .sidebarAppearance
        case "workspaceColors": return .workspaceColors
        case "automation": return .automation
        case "browser": return .browser
        case "notifications": return .app
        case "shortcuts": return .keyboardShortcuts
        case "integrations": return .account
        case "rightSidebar", "betaFeatures": return .betaFeatures
        default: return nil
        }
    }
}
