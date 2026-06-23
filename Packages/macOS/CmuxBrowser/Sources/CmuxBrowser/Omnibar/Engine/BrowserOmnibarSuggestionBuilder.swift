public import Foundation

/// Builds and ranks the omnibar suggestion list from the typed query and the
/// available candidate sources (history, open tabs, remote predictions, and the
/// pre-resolved navigable URL).
///
/// This is a pure value-in/value-out transform: it owns the legacy top-level
/// `buildOmnibarSuggestions` plus its autocompletion-prioritization and
/// single-character-prefix helpers, with all scoring, ordering, dedupe, and
/// autocompletion behavior preserved byte-for-byte. The view computes the input
/// candidate arrays and calls `build`.
public struct BrowserOmnibarSuggestionBuilder: Sendable {
    public init() {}

    /// Builds the ranked suggestion list for `query`.
    ///
    /// - Parameters:
    ///   - query: The raw typed query (trimmed internally).
    ///   - engineName: Display name of the active search engine.
    ///   - historyEntries: Candidate history rows, most-relevant first.
    ///   - openTabMatches: Candidate open-tab rows.
    ///   - remoteQueries: Remote search predictions for the query.
    ///   - resolvedURL: The navigable URL `query` resolves to, or `nil`.
    ///   - limit: Maximum rows to return.
    ///   - now: Clock used for history recency scoring (injected for tests).
    public func build(
        query: String,
        engineName: String,
        historyEntries: [BrowserHistoryEntry],
        openTabMatches: [OmnibarOpenTabMatch] = [],
        remoteQueries: [String],
        resolvedURL: URL?,
        limit: Int = 8,
        now: Date = Date()
    ) -> [OmnibarSuggestion] {
        guard limit > 0 else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return Array(historyEntries.prefix(limit).map { .history($0) })
        }
        let singleCharacterQuery = trimmedQuery.omnibarSingleCharacterQuery
        let isSingleCharacterQuery = singleCharacterQuery != nil
        let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
        let filteredHistoryEntries: [BrowserHistoryEntry]
        let filteredOpenTabMatches: [OmnibarOpenTabMatch]
        if let singleCharacterQuery {
            filteredHistoryEntries = historyEntries.filter {
                Self.hasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
            }
            filteredOpenTabMatches = openTabMatches.filter {
                Self.hasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
            }
        } else {
            filteredHistoryEntries = historyEntries
            filteredOpenTabMatches = openTabMatches
        }

        let shouldSuppressSingleCharacterSearchResult = isSingleCharacterQuery
            && (!filteredHistoryEntries.isEmpty || !filteredOpenTabMatches.isEmpty)

        struct RankedSuggestion {
            let suggestion: OmnibarSuggestion
            let score: Double
            let order: Int
            let isAutocompletableMatch: Bool
            let kindPriority: Int
        }

        var bestByCompletion: [String: RankedSuggestion] = [:]
        var order = 0
        let intent = OmnibarInputIntent.resolve(for: trimmedQuery, resolvedURL: resolvedURL)
        let normalizedQuery = trimmedQuery.lowercased()

        func suggestionPriority(for kind: OmnibarSuggestion.Kind) -> Int {
            switch kind {
            case .search:
                return 300
            case .remote:
                return 350
            default:
                return 0
            }
        }

        func completionScore(for candidate: String) -> Double {
            let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let q = normalizedQuery
            guard !c.isEmpty, !q.isEmpty else { return 0 }

            let scoringCandidate = c.omnibarScoringCandidate
            if !scoringCandidate.isEmpty {
                if scoringCandidate == q { return 260 }
                if scoringCandidate.hasPrefix(q) { return 220 }
                if scoringCandidate.contains(q) { return 150 }
            }

            if c == q { return 240 }
            if c.hasPrefix(q) { return 170 }
            if c.contains(q) { return 95 }
            return 0
        }

        func insert(_ suggestion: OmnibarSuggestion, score: Double) {
            let key = suggestion.completion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            let isAutocompletableMatch = suggestion.supportsAutocompletion(query: trimmedQuery)

            let ranked = RankedSuggestion(
                suggestion: suggestion,
                score: score,
                order: order,
                isAutocompletableMatch: isAutocompletableMatch,
                kindPriority: suggestionPriority(for: suggestion.kind)
            )
            order += 1
            if let existing = bestByCompletion[key] {
                let shouldReplaceExisting: Bool = {
                    // For identical completions, keep "go to URL" over "switch to tab" so
                    // pressing Enter performs navigation unless the user explicitly picks a tab row.
                    switch (existing.suggestion.kind, ranked.suggestion.kind) {
                    case (.navigate, .switchToTab):
                        return false
                    case (.switchToTab, .navigate):
                        return true
                    default:
                        return ranked.score > existing.score
                    }
                }()
                if shouldReplaceExisting {
                    bestByCompletion[key] = ranked
                }
            } else {
                bestByCompletion[key] = ranked
            }
        }

        if !(isSingleCharacterQuery && shouldSuppressSingleCharacterSearchResult) {
            let searchBaseScore: Double
            switch intent {
            case .queryLike: searchBaseScore = 820
            case .ambiguous: searchBaseScore = 540
            case .urlLike: searchBaseScore = 140
            }
            insert(.search(engineName: engineName, query: trimmedQuery), score: searchBaseScore + completionScore(for: trimmedQuery))
        }

        if let resolvedURL {
            let completion = resolvedURL.absoluteString
            let navigateBaseScore: Double
            switch intent {
            case .urlLike: navigateBaseScore = 1_020
            case .ambiguous: navigateBaseScore = 760
            case .queryLike: navigateBaseScore = 470
            }
            insert(.navigate(url: completion), score: navigateBaseScore + completionScore(for: completion))
        }

        for (index, entry) in filteredHistoryEntries.prefix(max(limit * 2, limit)).enumerated() {
            let intentBaseScore: Double
            switch intent {
            case .urlLike: intentBaseScore = 780
            case .ambiguous: intentBaseScore = 690
            case .queryLike: intentBaseScore = 600
            }
            let urlMatch = completionScore(for: entry.url)
            let titleMatch = completionScore(for: entry.title ?? "") * 0.6
            let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
            let recencyScore = max(0, 75 - (ageHours / 5))
            let visitScore = min(95, log1p(Double(max(1, entry.visitCount))) * 32)
            let typedScore = min(230, log1p(Double(max(0, entry.typedCount))) * 100)
            let typedRecencyScore: Double
            if let lastTypedAt = entry.lastTypedAt {
                let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
                typedRecencyScore = max(0, 80 - (typedAgeHours / 5))
            } else {
                typedRecencyScore = 0
            }
            let positionScore = Double(max(0, 16 - index))
            let total = intentBaseScore + urlMatch + titleMatch + recencyScore + visitScore + typedScore + typedRecencyScore + positionScore
            insert(.history(entry), score: total)
        }

        for (index, match) in filteredOpenTabMatches.prefix(limit).enumerated() {
            let intentBaseScore: Double
            switch intent {
            case .urlLike: intentBaseScore = 1_180
            case .ambiguous: intentBaseScore = 980
            case .queryLike: intentBaseScore = 820
            }
            let urlMatch = completionScore(for: match.url)
            let titleMatch = completionScore(for: match.title ?? "") * 0.65
            let positionScore = Double(max(0, 14 - index)) * 0.9
            let resolvedURLBonus: Double
            if let resolvedURL,
               resolvedURL.absoluteString.caseInsensitiveCompare(match.url) == .orderedSame {
                resolvedURLBonus = 120
            } else {
                resolvedURLBonus = 0
            }
            let total = intentBaseScore + urlMatch + titleMatch + positionScore + resolvedURLBonus
            if match.isKnownOpenTab {
                insert(
                    .switchToTab(tabId: match.tabId, panelId: match.panelId, url: match.url, title: match.title),
                    score: total
                )
            } else {
                insert(
                    OmnibarSuggestion.history(url: match.url, title: match.title),
                    score: total
                )
            }
        }

        if shouldIncludeRemoteSuggestions {
            for (index, remoteQuery) in remoteQueries.prefix(limit).enumerated() {
                let trimmedRemote = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedRemote.isEmpty else { continue }

                let remoteBaseScore: Double
                switch intent {
                case .queryLike: remoteBaseScore = 690
                case .ambiguous: remoteBaseScore = 450
                case .urlLike: remoteBaseScore = 110
                }
                let positionScore = Double(max(0, 14 - index)) * 0.9
                let total = remoteBaseScore + completionScore(for: trimmedRemote) + positionScore
                insert(.remoteSearchSuggestion(trimmedRemote), score: total)
            }
        }

        let sorted = bestByCompletion.values.sorted { lhs, rhs in
            if lhs.isAutocompletableMatch != rhs.isAutocompletableMatch {
                return lhs.isAutocompletableMatch
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.kindPriority != rhs.kindPriority {
                return lhs.kindPriority < rhs.kindPriority
            }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.suggestion.completion < rhs.suggestion.completion
        }
        let suggestions = Array(sorted.map(\.suggestion).prefix(limit))
        return Self.prioritizedAutocompletionSuggestions(suggestions: Array(suggestions), for: trimmedQuery)
    }

    /// Whether a single-character `query` prefixes `url` (scheme/`www`-stripped)
    /// or `title`.
    public static func hasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
        guard let trimmedQuery = query.omnibarSingleCharacterQuery else { return false }

        let normalizedURL = url.omnibarSchemeAndWWWStripped.lowercased()
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
    }

    /// Returns previously-fetched remote suggestions to keep visible while a new
    /// fetch is in flight, when the new query is prefix-compatible with the
    /// previous remote query.
    public static func staleRemoteSuggestionsForDisplay(
        query: String,
        previousRemoteQuery: String,
        previousRemoteSuggestions: [String],
        allowsRemoteSuggestions: Bool = true,
        limit: Int = 8
    ) -> [String] {
        guard allowsRemoteSuggestions else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPreviousQuery = previousRemoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredQuery = trimmedQuery.lowercased()
        let loweredPreviousQuery = trimmedPreviousQuery.lowercased()
        guard !trimmedQuery.isEmpty, !trimmedPreviousQuery.isEmpty else { return [] }
        guard loweredQuery == loweredPreviousQuery || loweredQuery.hasPrefix(loweredPreviousQuery) || loweredPreviousQuery.hasPrefix(loweredQuery) else {
            return []
        }
        guard !previousRemoteSuggestions.isEmpty else { return [] }
        let sanitized = previousRemoteSuggestions.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }

        if sanitized.isEmpty {
            return []
        }
        return Array(sanitized.prefix(limit))
    }

    private static func prioritizedAutocompletionSuggestions(suggestions: [OmnibarSuggestion], for query: String) -> [OmnibarSuggestion] {
        guard let preferred = preferredAutocompletionSuggestionIndex(
            suggestions: suggestions,
            query: query
        ) else {
            return suggestions
        }

        guard preferred != 0 else { return suggestions }

        var reordered = suggestions
        let suggestion = reordered.remove(at: preferred)
        reordered.insert(suggestion, at: 0)
        return reordered
    }

    /// Index of the suggestion the omnibar should auto-select for inline
    /// completion (shortest autocompletable suffix wins, ties broken by order),
    /// or `nil` when none applies.
    static func preferredAutocompletionSuggestionIndex(
        suggestions: [OmnibarSuggestion],
        query: String
    ) -> Int? {
        guard !query.isEmpty else { return nil }

        var candidates: [(idx: Int, suffixLength: Int)] = []
        for (idx, suggestion) in suggestions.enumerated() {
            guard suggestion.supportsAutocompletion(query: query) else { continue }
            guard let completion = suggestion.navigableCompletion else { continue }
            let displayCompletion = OmnibarSuggestion.matchesTypedPrefix(
                typedText: query,
                suggestionCompletion: completion,
                suggestionTitle: suggestion.matchTitle
            ) ? completion : ""
            guard !displayCompletion.isEmpty else { continue }

            let suffixLength = max(
                0,
                suggestionDisplayText(forPrefixing: displayCompletion, query: query).utf16.count - query.utf16.count
            )
            candidates.append((idx: idx, suffixLength: suffixLength))
        }

        guard let preferred = candidates.min(by: {
            if $0.suffixLength != $1.suffixLength {
                return $0.suffixLength < $1.suffixLength
            }
            return $0.idx < $1.idx
        })?.idx else {
            return nil
        }

        return preferred
    }

    private static func suggestionDisplayText(forPrefixing completion: String, query: String) -> String {
        let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
        let typedIncludesWWWPrefix = query.hasPrefix("www.")
        if typedIncludesScheme {
            return completion
        }
        if typedIncludesWWWPrefix {
            return completion.omnibarSchemeStripped
        }
        return completion.omnibarSchemeAndWWWStripped
    }
}
