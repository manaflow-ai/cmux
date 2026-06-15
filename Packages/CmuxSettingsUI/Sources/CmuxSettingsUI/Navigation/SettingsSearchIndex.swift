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
/// 3. Catalog fallback entries for every ``SettingCatalog`` key not
///    claimed by a curated row. Those fallbacks navigate to the owning
///    section, which prevents newly-added settings from silently
///    becoming impossible to search before a curated row synonym is
///    written.
///
/// Diacritic-insensitive matching via
/// `String.folding(options:locale:)`. Matching is per-token AND: every
/// whitespace/punct-separated token in the query must match somewhere
/// in the entry's normalized search text. Ranking prefers exact and
/// prefix matches, then literal substring matches, then typo-tolerant
/// and subsequence matches.
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
        let normalizedSearchWords: [String]
        let normalizedSearchWordSet: Set<String>
        public let anchorID: String

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
            self.normalizedSearchWords = SettingsSearchIndex.tokens(in: normalizedSearchText)
            self.normalizedSearchWordSet = Set(normalizedSearchWords)
            self.anchorID = anchorID
        }
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

    /// Builds an index from the section list, supplied curated entries,
    /// and catalog fallback keys.
    ///
    /// - Parameters:
    ///   - catalog: Source of fallback settings so every real catalog
    ///     key remains searchable even before it gains a row-specific
    ///     curated synonym entry.
    ///   - curatedEntries: One entry per searchable setting row, with a
    ///     localized title + synonyms. Defaults to
    ///     ``Swift/Array/cmuxDefault`` — the table the cmux app ships
    ///     with. Tests pass an empty array or a focused subset; hosts
    ///     can append their own entries to expose additional rows.
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
                    "\(section.rawValue) \(section.title) \(section.searchKeywords) \(Self.humanizedIdentifier(section.rawValue))"
                ),
                anchorID: "section:\(section.rawValue)"
            ))
        }

        var pathAnchors: [String: String] = [:]
        var coveredCatalogPaths = Set<String>()

        for entry in curatedEntries {
            let entryID = "setting:\(entry.section.rawValue):\(entry.id)"
            let searchPaths = entry.paths.isEmpty
                ? Self.dottedTokens(in: entry.synonyms)
                : entry.paths
            let pathSearchText = searchPaths.flatMap(Self.searchTokens(forSettingPath:)).joined(separator: " ")
            built.append(Entry(
                id: entryID,
                kind: .setting(parent: entry.section),
                title: entry.title,
                symbolName: entry.section.symbolName,
                normalizedSearchText: Self.normalize(
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

            for path in searchPaths {
                coveredCatalogPaths.insert(path)
                if pathAnchors[path] == nil { pathAnchors[path] = entryID }
            }
        }

        for key in catalog.all where !coveredCatalogPaths.contains(key.id) {
            guard let section = Self.section(forSettingPath: key.id) else { continue }
            let sectionID = "section:\(section.rawValue)"
            built.append(Entry(
                id: "setting:\(section.rawValue):catalog-\(Self.slug(forSettingPath: key.id))",
                kind: .setting(parent: section),
                title: Self.title(forSettingPath: key.id),
                symbolName: section.symbolName,
                normalizedSearchText: Self.normalize(
                    [
                        section.rawValue,
                        section.title,
                        section.searchKeywords,
                        key.id,
                        Self.searchTokens(forSettingPath: key.id).joined(separator: " "),
                        Self.storageSearchText(for: key)
                    ].joined(separator: " ")
                ),
                anchorID: sectionID
            ))
        }

        self.entries = built
        self.pathAnchorIDs = pathAnchors
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
        return entries.enumerated()
            .compactMap { offset, entry -> (entry: Entry, score: Int, offset: Int)? in
                guard let score = Self.matchScore(entry: entry, query: normalizedQuery, tokens: tokens) else {
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

    private static func matchScore(entry: Entry, query: String, tokens: [String]) -> Int? {
        var score = 0
        for token in tokens {
            guard let tokenScore = Self.matchScore(
                token: token,
                text: entry.normalizedSearchText,
                words: entry.normalizedSearchWords,
                wordSet: entry.normalizedSearchWordSet
            ) else {
                return nil
            }
            score += tokenScore
        }

        let title = Self.normalize(entry.title)
        if title == query { score -= 1_000 }
        if title.hasPrefix(query) { score -= 800 }
        if Self.containsAtWordBoundary(query, in: title) { score -= 700 }
        if entry.normalizedSearchText.hasPrefix(query) { score -= 600 }
        if Self.containsAtWordBoundary(query, in: entry.normalizedSearchText) { score -= 500 }
        if entry.normalizedSearchText.contains(query) { score -= 400 }
        if case .section = entry.kind { score += 25 }
        return score
    }

    private static func matchScore(token: String, text: String, words: [String], wordSet: Set<String>) -> Int? {
        if wordSet.contains(token) { return 0 }
        if words.contains(where: { $0.hasPrefix(token) }) { return 10 }
        if Self.containsAtWordBoundary(token, in: text) { return 20 }
        if text.contains(token) { return 30 }
        if words.contains(where: { Self.isLightTypo(token, comparedTo: $0) }) { return 50 }
        if words.contains(where: { Self.isSubsequence(token, of: $0) }) { return 60 }
        if Self.isSubsequence(token, of: text) { return 80 }
        return nil
    }

    private static func containsAtWordBoundary(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return true
            }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if !previous.isLetter, !previous.isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in haystack where character == needle[index] {
            index = needle.index(after: index)
            if index == needle.endIndex { return true }
        }
        return false
    }

    private static func isLightTypo(_ token: String, comparedTo word: String) -> Bool {
        guard token.count >= 4, word.count >= 4 else { return false }
        let allowedDistance = min(token.count, word.count) >= 6 ? 2 : 1
        return Self.editDistance(token, word, maximum: allowedDistance) <= allowedDistance
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maximum { return maximum + 1 }
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let cost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private static func dottedTokens(in text: String) -> [String] {
        text.split(separator: " ")
            .map(String.init)
            .filter { $0.contains(".") }
    }

    private static func searchTokens(forSettingPath path: String) -> [String] {
        [path, Self.humanizedIdentifier(path)]
    }

    private static func humanizedIdentifier(_ identifier: String) -> String {
        var result = ""
        var previousWasLowercaseOrDigit = false
        for character in identifier {
            if character == "." || character == "-" || character == "_" {
                result.append(" ")
                previousWasLowercaseOrDigit = false
                continue
            }
            if character.isUppercase, previousWasLowercaseOrDigit {
                result.append(" ")
            }
            result.append(character)
            previousWasLowercaseOrDigit = character.isLowercase || character.isNumber
        }
        return result
    }

    private static func title(forSettingPath path: String) -> String {
        Self.humanizedIdentifier(path.split(separator: ".").last.map(String.init) ?? path)
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }

    private static func slug(forSettingPath path: String) -> String {
        Self.normalize(Self.humanizedIdentifier(path))
            .split(separator: " ")
            .joined(separator: "-")
    }

    private static func storageSearchText(for key: AnySettingKey) -> String {
        switch key.kind {
        case .userDefaults(let key, _, let legacyKeys):
            return ([key] + legacyKeys).joined(separator: " ")
        case .jsonConfig:
            return "cmux json config"
        case .secretFile(let fileName):
            return "secret file \(fileName)"
        }
    }

    private static func section(forSettingPath path: String) -> SettingsSectionID? {
        guard let prefix = path.split(separator: ".").first.map(String.init) else { return nil }
        switch prefix {
        case "account":
            return .account
        case "app", "notifications", "workspaceGroups", "markdown", "canvas", "fileEditor":
            return .app
        case "terminal":
            return .terminal
        case "sidebar", "sidebarAppearance":
            return .sidebarAppearance
        case "workspaceColors":
            return .workspaceColors
        case "automation", "integrations":
            return .automation
        case "browser":
            return .browser
        case "mobile":
            return .mobile
        case "customSidebars":
            return .customSidebars
        case "rightSidebar":
            return .betaFeatures
        case "shortcuts":
            return .keyboardShortcuts
        default:
            return nil
        }
    }
}
