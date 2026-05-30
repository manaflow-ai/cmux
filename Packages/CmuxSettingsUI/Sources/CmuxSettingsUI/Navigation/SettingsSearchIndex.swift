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

    /// Maps a dotted cmux.json path (e.g. `sidebar.showBranchDirectory`)
    /// to the stable anchor id of the entry that owns it. Lets a
    /// ``SettingsCardRow`` resolve the config path it already declares
    /// via ``SettingsConfigurationReview`` into the scroll/highlight
    /// target the navigation layer posts, without a second
    /// hand-maintained id table. Built from the curated entries' dotted
    /// synonym tokens.
    private let pathAnchorIDs: [String: String]

    /// The set of every entry id in ``entries``, used to validate the
    /// `setting:<path>` fallback so a row never anchors to an id that no
    /// search hit can navigate to.
    private let entryIDs: Set<String>

    /// Builds an index from the section list, the supplied curated
    /// entries, and any remaining ``SettingCatalog/all`` keys not
    /// already covered by the curated table.
    ///
    /// - Parameters:
    ///   - catalog: The settings catalog whose dotted-id keys back-fill
    ///     the index for entries not in ``curatedEntries``.
    ///   - curatedEntries: High-signal entries with curated titles +
    ///     synonyms. Defaults to ``Swift/Array/cmuxDefault`` — the
    ///     table the cmux app ships with. Tests pass an empty array
    ///     or a focused subset to exercise specific behavior; hosts
    ///     can append their own entries to the default to add new
    ///     searchable surfaces without forking.
    public init(
        catalog: SettingCatalog,
        curatedEntries: [CuratedSettingEntry] = .cmuxDefault
    ) {
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

        for entry in curatedEntries {
            built.append(Entry(
                id: "setting:\(entry.section.rawValue):\(entry.id)",
                kind: .setting(parent: entry.section),
                title: entry.title,
                symbolName: entry.section.symbolName,
                normalizedSearchText: Self.normalize(
                    "\(entry.title) \(entry.synonyms)"
                )
            ))
        }

        for key in catalog.all
        where !Self.isCovered(by: curatedEntries, keyID: key.id) {
            // Catalog keys that the curated table already covers
            // surface there with their natural title; this back-fill
            // is for keys nobody has written a curated entry for yet.
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
        self.entryIDs = Set(built.map(\.id))

        // Curated synonym strings lead with the setting's dotted
        // cmux.json path (e.g. "sidebar.showBranchDirectory git …"),
        // which is exactly what a row declares via its
        // configurationReview. Index every dotted token to the curated
        // entry's anchor id so a row can map its path to a scroll target.
        // First writer wins: a dotted path is owned by one setting.
        var pathAnchors: [String: String] = [:]
        for entry in curatedEntries {
            let anchorID = "setting:\(entry.section.rawValue):\(entry.id)"
            for token in entry.synonyms.split(separator: " ") where token.contains(".") {
                let path = String(token)
                if pathAnchors[path] == nil { pathAnchors[path] = anchorID }
            }
        }
        self.pathAnchorIDs = pathAnchors
    }

    /// Resolves a dotted cmux.json path to the anchor id the
    /// sidebar/search navigation scrolls to and highlights.
    ///
    /// Returns the curated entry's anchor id when the path is covered by
    /// a curated synonym, otherwise the `setting:<path>` fallback id when
    /// such a raw catalog entry exists, otherwise `nil` (the path has no
    /// navigable search hit).
    ///
    /// - Parameter path: A dotted cmux.json path, e.g. `terminal.copyOnSelect`.
    /// - Returns: The stable entry id to use as a `scrollTo` / highlight
    ///   anchor, or `nil` when nothing in the index targets `path`.
    public func anchorID(forSettingsPath path: String) -> String? {
        if let curated = pathAnchorIDs[path] { return curated }
        let fallback = "setting:\(path)"
        return entryIDs.contains(fallback) ? fallback : nil
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

    /// A curated entry covers a catalog key when the entry's synonym
    /// string contains the catalog key's dotted id. Avoids surfacing
    /// the same setting twice (once with a curated title, once with
    /// the raw dotted id).
    private static func isCovered(
        by curatedEntries: [CuratedSettingEntry],
        keyID: String
    ) -> Bool {
        for entry in curatedEntries where entry.synonyms.contains(keyID) {
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
