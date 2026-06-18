import CmuxSettings
import Foundation

/// Fuzzy-match index over ``SettingsSectionID`` titles and searchable
/// per-setting entries.
///
/// Two classes of entries are indexed:
///
/// 1. Section entries — one per ``SettingsSectionID`` case — surfaced
///    in the sidebar by default (empty query).
/// 2. Curated setting entries from ``CuratedSettingEntries/entries`` —
///    one per high-signal row in the detail pane, with the user-facing
///    localized title, row detail text, config paths, and synonyms.
///    This is what makes search useful: typing "copy on select" finds
///    the `terminal.copyOnSelect` row even though that's an internal id.
///
/// Diacritic-insensitive matching via
/// `String.folding(options:locale:)`. Matching is per-token AND: every
/// whitespace/punct-separated token in the query must match somewhere
/// in the entry's normalized search text. Ranking prefers exact and
/// prefix matches, then literal substring matches, then typo-tolerant
/// and subsequence matches.
public struct SettingsSearchIndex: Sendable {
    /// A searchable sidebar result representing either a settings section or a specific setting row.
    public struct Entry: Sendable, Identifiable, Hashable {
        /// The destination category for a search result.
        public enum Kind: Sendable, Hashable {
            /// A top-level settings section result.
            case section
            /// A setting row result that belongs to the associated parent section.
            case setting(parent: SettingsSectionID)
        }

        /// Stable identifier used by SwiftUI list selection and search-result diffing.
        public let id: String
        /// Whether the result selects a section or a setting row inside a section.
        public let kind: Kind
        /// User-facing title shown in the search results list.
        public let title: String
        /// SF Symbol name rendered next to the result title.
        public let symbolName: String
        /// Case- and diacritic-folded text searched by ``match(_:)``.
        public let normalizedSearchText: String
        /// Tokenized form of ``normalizedSearchText`` cached for per-query scoring.
        let normalizedSearchWords: [String]
        /// Unique token set cached so exact token matches stay O(1) per query token.
        let normalizedSearchWordSet: Set<String>
        /// Anchor id posted to the settings content scroll view when the result is selected.
        public let anchorID: String

        /// Creates a search index entry and precomputes its searchable token caches.
        ///
        /// - Parameters:
        ///   - id: Stable search-result identifier.
        ///   - kind: Result destination category.
        ///   - title: User-facing result title.
        ///   - symbolName: SF Symbol rendered with the result.
        ///   - normalizedSearchText: Already-normalized search text to score against.
        ///   - anchorID: Scroll/highlight anchor selected when the result is activated.
        init(
            id: String,
            kind: Kind,
            title: String,
            symbolName: String,
            normalizedSearchText: String,
            anchorID: String
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.symbolName = symbolName
            self.normalizedSearchText = normalizedSearchText
            self.normalizedSearchWords = SettingsSearchMatcher().tokens(in: normalizedSearchText)
            self.normalizedSearchWordSet = Set(normalizedSearchWords)
            self.anchorID = anchorID
        }
    }

    /// All indexed entries in their default display order.
    public let entries: [Entry]

    /// Search text normalizer and scorer used for query matching.
    private let matcher: SettingsSearchMatcher

    /// Maps a dotted cmux.json path (e.g. `sidebar.showBranchDirectory`)
    /// to the stable anchor id of the entry that owns it. Lets a
    /// ``SettingsCardRow`` resolve the config path it already declares
    /// via ``SettingsConfigurationReview`` into the scroll/highlight
    /// target the navigation layer posts, without a second
    /// hand-maintained id table. Built from curated entry paths, or from
    /// dotted synonym tokens for legacy entries.
    private let pathAnchorIDs: [String: String]

    /// Builds an index from the section list and supplied curated entries.
    ///
    /// - Parameters:
    ///   - catalog: Settings catalog used by host call sites. Search
    ///     visibility is intentionally driven by `curatedEntries`, not
    ///     by every persisted catalog key, because some catalog keys are
    ///     hidden/internal state with no visible row to scroll to.
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
        let matcher = SettingsSearchMatcher()
        var built: [Entry] = []

        for section in SettingsSectionID.allCases {
            built.append(Entry(
                id: "section:\(section.rawValue)",
                kind: .section,
                title: section.title,
                symbolName: section.symbolName,
                normalizedSearchText: matcher.normalize(
                    "\(section.rawValue) \(section.title) \(section.searchKeywords) \(matcher.humanizedIdentifier(section.rawValue))"
                ),
                anchorID: "section:\(section.rawValue)"
            ))
        }

        var pathAnchors: [String: String] = [:]

        for entry in curatedEntries {
            let entryID = "setting:\(entry.section.rawValue):\(entry.id)"
            let searchPaths = entry.paths.isEmpty
                ? matcher.dottedTokens(in: entry.synonyms)
                : entry.paths
            let pathSearchText = searchPaths.flatMap { matcher.searchTokens(forSettingPath: $0) }.joined(separator: " ")
            built.append(Entry(
                id: entryID,
                kind: .setting(parent: entry.section),
                title: entry.title,
                symbolName: entry.section.symbolName,
                normalizedSearchText: matcher.normalize(
                    [
                        entry.section.rawValue,
                        entry.section.title,
                        entry.section.searchKeywords,
                        entry.id,
                        entry.title,
                        entry.detailText,
                        searchPaths.joined(separator: " "),
                        pathSearchText,
                        entry.synonyms
                    ].joined(separator: " ")
                ),
                anchorID: entryID
            ))

            let anchorPaths = entry.anchorPath.map { [$0] } ?? searchPaths
            for path in anchorPaths {
                if pathAnchors[path] == nil { pathAnchors[path] = entryID }
            }
        }

        self.entries = built
        self.matcher = matcher
        self.pathAnchorIDs = pathAnchors
    }

    /// Returns entries whose indexed text matches every token in `query`, sorted by relevance.
    ///
    /// Empty queries return section entries only. Non-empty queries use exact, prefix,
    /// word-boundary, substring, light-typo, and subsequence matching while preserving
    /// declaration order as the final tie-breaker.
    ///
    /// - Parameter query: User-entered settings search text.
    /// - Returns: Matching entries sorted from best to worst match.
    public func match(_ query: String) -> [Entry] {
        #if DEBUG
        // Debug-only escape hatch: typing the sentinel surfaces *every*
        // indexed entry (sections + settings) at once, so search/scroll/
        // highlight can be walked end to end by tapping each result. The
        // raw query is compared before tokenization so the sentinel's
        // punctuation isn't stripped. Compiled out of Release builds.
        if matcher.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines) == matcher.debugShowAllQuery {
            return entries
        }
        #endif
        let tokens = matcher.queryTokens(in: query)
        if tokens.isEmpty {
            return entries.filter { if case .section = $0.kind { return true } else { return false } }
        }
        let normalizedQuery = matcher.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.enumerated()
            .compactMap { offset, entry -> (entry: Entry, score: Int, offset: Int)? in
                guard let score = matcher.matchScore(entry: entry, query: normalizedQuery, tokens: tokens) else {
                    return nil
                }
                return (entry, score, offset)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.offset < rhs.offset
            }
            .map(\.entry)
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
}
