import CmuxSettings
import Foundation

/// Fuzzy-match index over ``SettingsSectionID`` titles and the curated
/// per-setting entries in ``CuratedSettingEntries``.
///
/// Two classes of entries are indexed:
///
/// 1. Section entries — one per ``SettingsSectionID`` case — surfaced
///    in the sidebar by default (empty query).
/// 2. Curated setting entries from ``CuratedSettingEntries/entries`` —
///    one per setting *that has a row in the detail pane*, with the
///    user-facing localized title plus a synonym string. This is what
///    makes search useful: typing "copy on select" finds the
///    `terminal.copyOnSelect` row even though that's an internal id.
///
/// The index deliberately does **not** back-fill raw ``SettingCatalog``
/// keys. Catalog keys without a curated entry have no UI row, so
/// surfacing them as search hits (e.g. `account.welcomeShown`) would
/// navigate to nothing. Search results stay limited to what actually
/// appears in the settings detail.
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

    /// Builds an index from the section list and the supplied curated
    /// entries. Raw ``SettingCatalog`` keys are intentionally not
    /// indexed (see the type doc): only settings with a real detail-pane
    /// row are searchable.
    ///
    /// - Parameters:
    ///   - catalog: Accepted for API symmetry and possible future
    ///     scoping; the index is built only from sections and curated
    ///     entries, so passing the app's full catalog does not widen the
    ///     searchable surface.
    ///   - curatedEntries: One entry per searchable setting row, with a
    ///     localized title + synonyms. Defaults to
    ///     ``Swift/Array/cmuxDefault`` — the table the cmux app ships
    ///     with. Tests pass an empty array or a focused subset; hosts
    ///     can append their own entries to expose additional rows.
    public init(
        catalog: SettingCatalog,
        curatedEntries: [CuratedSettingEntry] = .cmuxDefault
    ) {
        _ = catalog
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

        self.entries = built

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

    /// Resolves a dotted cmux.json path to the curated entry id the
    /// sidebar/search navigation scrolls to and highlights, so a row can
    /// tag itself with the exact id its search hit posts.
    ///
    /// Returns `nil` when no curated entry claims `path`. Every settings
    /// row's `configurationReview` path must resolve here, or its search
    /// hit scrolls and pulses nothing — `SettingsRowAnchorResolutionTests`
    /// enforces that across all rows.
    ///
    /// - Parameter path: A dotted cmux.json path, e.g. `terminal.copyOnSelect`.
    /// - Returns: The curated entry id to use as a `scrollTo` / highlight
    ///   anchor, or `nil` when no curated entry owns `path`.
    public func anchorID(forSettingsPath path: String) -> String? {
        pathAnchorIDs[path]
    }

    public func match(_ query: String) -> [Entry] {
        #if DEBUG
        // Debug-only escape hatch: typing the sentinel surfaces *every*
        // indexed entry (sections + settings) at once, so search/scroll/
        // highlight can be walked end to end by tapping each result. The
        // raw query is compared before tokenization so the sentinel's
        // punctuation isn't stripped. Compiled out of Release builds.
        if Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines) == Self.debugShowAllQuery {
            return entries
        }
        #endif
        let tokens = Self.tokens(in: query)
        if tokens.isEmpty {
            return entries.filter { if case .section = $0.kind { return true } else { return false } }
        }
        return entries.filter { entry in
            tokens.allSatisfy { entry.normalizedSearchText.contains($0) }
        }
    }

    #if DEBUG
    /// Sentinel search query that, in DEBUG builds only, makes
    /// ``match(_:)`` return every indexed entry so the full search →
    /// scroll → highlight path can be exercised one row at a time.
    static let debugShowAllQuery = ":all"
    #endif

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

}
