import CmuxSettings
import Foundation

/// Fuzzy-match index over ``SettingsSectionID`` titles and the curated
/// per-setting entries in ``CuratedSettingEntries``.
///
/// Three classes of entries are indexed:
///
/// 1. Section entries — one per ``SettingsSectionID`` case — surfaced
///    in the sidebar by default (empty query).
/// 2. Curated setting entries from ``CuratedSettingEntries/entries`` —
///    one per high-signal setting, with the user-facing localized
///    title plus a synonym string mined from the legacy index. This is
///    what makes search useful: typing "copy on select" finds the
///    `terminal.copyOnSelect` row even though that's an internal id.
/// 3. Fallback dotted-id entries built from ``SettingCatalog/all`` for
///    catalog keys that are *not* covered by the curated table. They
///    only match on the dotted id, which is a usable last-resort path
///    for power users who know the underlying key.
///
/// Diacritic-insensitive matching via
/// `String.folding(options:locale:)`. Matching is per-token AND: every
/// whitespace/punct-separated token in the query must appear somewhere
/// in the entry's normalized search text.
public struct SettingsSearchIndex: Sendable {
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

    public init(catalog: SettingCatalog) {
        var built: [Entry] = []
        var curatedSettingIDs = Set<String>()

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

        for entry in CuratedSettingEntries.entries {
            let stableID = "setting:\(entry.section.rawValue):\(entry.id)"
            curatedSettingIDs.insert(entry.id)
            built.append(Entry(
                id: stableID,
                kind: .setting(parent: entry.section),
                title: entry.title,
                symbolName: entry.section.symbolName,
                normalizedSearchText: Self.normalize(
                    "\(entry.title) \(entry.synonyms)"
                )
            ))
        }

        for key in catalog.all {
            // Skip catalog keys that already have a curated entry. The
            // curated row is the higher-quality surface; we don't want
            // both showing up as duplicate results for the same setting.
            if Self.isCovered(by: curatedSettingIDs, keyID: key.id) { continue }
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

    public func match(_ query: String) -> [Entry] {
        let tokens = Self.tokens(in: query)
        if tokens.isEmpty {
            return entries.filter { if case .section = $0.kind { return true } else { return false } }
        }
        return entries.filter { entry in
            tokens.allSatisfy { entry.normalizedSearchText.contains($0) }
        }
    }

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

    /// Heuristic check: a curated entry covers a catalog key when the
    /// curated synonyms contain the catalog key's dotted id. Avoids the
    /// O(n*m) cost of comparing each curated synonym list against each
    /// key while still catching most duplicates.
    private static func isCovered(by curated: Set<String>, keyID: String) -> Bool {
        for entry in CuratedSettingEntries.entries
        where entry.synonyms.contains(keyID) {
            return true
        }
        return false
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
