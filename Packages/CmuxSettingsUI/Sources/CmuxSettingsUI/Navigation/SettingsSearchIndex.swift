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
/// `String.folding(options:locale:)`. Matching is per-token AND with
/// ranking: every whitespace/punct-separated query token must match an
/// entry token by exact, word-prefix, substring, bounded fuzzy, or
/// subsequence match.
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

        // Existing curated synonym strings lead with the setting's
        // dotted cmux.json path (e.g. "sidebar.showBranchDirectory
        // git …"), which is exactly what a row declares via its
        // configurationReview. New entries can set `anchorPath`
        // explicitly when localized search synonyms also contain
        // secondary dotted tokens that should not become row anchors.
        // First writer wins: a dotted path is owned by one setting.
        var pathAnchors: [String: String] = [:]
        for entry in curatedEntries {
            let anchorID = "setting:\(entry.section.rawValue):\(entry.id)"
            let anchorPaths = entry.anchorPath.map { [$0] }
                ?? entry.synonyms.split(separator: " ").compactMap { token in
                    token.contains(".") ? String(token) : nil
                }
            for path in anchorPaths {
                if pathAnchors[path] == nil {
                    pathAnchors[path] = anchorID
                }
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
        let normalizedQuery = Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.enumerated().compactMap { index, entry -> (entry: Entry, score: Int, index: Int)? in
            guard let score = Self.matchScore(entry, tokens: tokens, normalizedQuery: normalizedQuery) else { return nil }
            return (entry, score, index)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        .map { $0.entry }
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

    private static func matchScore(_ entry: Entry, tokens queryTokens: [String], normalizedQuery: String) -> Int? {
        var total = 0
        // An exact title match is the strongest possible signal and must
        // outrank rows that match only via synonyms. Without this, typing a
        // section name (e.g. "automation") ranked child settings above the
        // section itself, because their dotted-path synonyms ("automation.*")
        // match the query and settings carry the +20 bonus below.
        if Self.normalize(entry.title) == normalizedQuery { total += 1_000 }
        if case .setting = entry.kind { total += 20 }
        if entry.normalizedSearchText.contains(normalizedQuery) { total += 50 }
        for token in queryTokens {
            guard let score = tokenScore(token, in: entry.normalizedSearchText) else { return nil }
            total += score
        }
        return total
    }

    private static func tokenScore(_ token: String, in normalizedSearchText: String) -> Int? {
        let words = tokens(in: normalizedSearchText)
        if words.contains(token) { return 120 }
        if words.contains(where: { $0.hasPrefix(token) }) { return 100 }
        if normalizedSearchText.contains(token) { return 80 }
        if words.contains(where: { isFuzzyMatch(token, word: $0) }) { return 60 }
        if words.contains(where: { isSubsequence(token, of: $0) }) { return 40 }
        return nil
    }

    private static func isFuzzyMatch(_ token: String, word: String) -> Bool {
        let tokenLength = token.count
        let wordLength = word.count
        guard min(tokenLength, wordLength) >= 4 else { return false }
        let maxDistance = min(tokenLength, wordLength) >= 7 ? 2 : 1
        guard abs(tokenLength - wordLength) <= maxDistance else { return false }
        return editDistance(token, word, maxDistance: maxDistance) <= maxDistance
    }

    private static func isSubsequence(_ token: String, of word: String) -> Bool {
        guard token.count >= 3, token.count <= word.count else { return false }
        var tokenIndex = token.startIndex
        for character in word where character == token[tokenIndex] {
            token.formIndex(after: &tokenIndex)
            if tokenIndex == token.endIndex { return true }
        }
        return false
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        if lhsCharacters.isEmpty { return rhsCharacters.count }
        if rhsCharacters.isEmpty { return lhsCharacters.count }

        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for lhsIndex in 1...lhsCharacters.count {
            current[0] = lhsIndex
            var rowMinimum = current[0]
            for rhsIndex in 1...rhsCharacters.count {
                let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rhsIndex])
            }
            if rowMinimum > maxDistance { return maxDistance + 1 }
            swap(&previous, &current)
        }

        return previous[rhsCharacters.count]
    }

}
