public import Foundation

/// Orchestrates one palette search across both engines: prefers the nucleo
/// FFI index when available, falls back to the Swift engine, and merges in
/// Swift single-edit (typo) matches that nucleo cannot produce.
///
/// A stateless service value: construct one with `init()` and drive a search
/// through the instance methods. The pure decision/transform helpers it relies
/// on stay `static`.
public struct CommandPaletteSearchOrchestrator: Sendable {
    private static let synchronousSeedCorpusLimit = 256
    private static let singleEditFallbackNucleoProbeLimit = 12

    /// Creates a search orchestrator.
    public init() {}

    /// Keys `values` by `key`, keeping the first element per key.
    public static func firstValueDictionary<Element, Key: Hashable>(
        _ values: [Element],
        keyedBy key: (Element) -> Key
    ) -> [Key: Element] {
        var dictionary: [Key: Element] = [:]
        dictionary.reserveCapacity(values.count)
        for value in values where dictionary[key(value)] == nil {
            dictionary[key(value)] = value
        }
        return dictionary
    }

    /// Resolves matches for `query` over the corpus, merging nucleo results
    /// with Swift single-edit fallback matches when needed.
    public func resolvedSearchMatches(
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        searchCorpusByID providedSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>]? = nil,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        additionalScoreBoost: ((String, Bool) -> Int)? = nil,
        resultLimit: Int? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [CommandPaletteResolvedSearchMatch] {
        let nucleoResultLimit = resultLimit ?? searchCorpus.count
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let historyBoost: ((String, Bool) -> Int)? = usageHistory.isEmpty ? nil : { commandId, queryIsEmpty in
            Self.historyBoost(
                for: commandId,
                queryIsEmpty: queryIsEmpty,
                history: usageHistory,
                now: historyTimestamp
            )
        }
        let scoreBoost: ((String, Bool) -> Int)? = {
            switch (historyBoost, additionalScoreBoost) {
            case (nil, nil):
                return nil
            case (let historyBoost?, nil):
                return historyBoost
            case (nil, let additionalScoreBoost?):
                return additionalScoreBoost
            case (let historyBoost?, let additionalScoreBoost?):
                return { commandId, queryIsEmpty in
                    historyBoost(commandId, queryIsEmpty) + additionalScoreBoost(commandId, queryIsEmpty)
                }
            }
        }()

        func swiftSearchMatches() -> [CommandPaletteResolvedSearchMatch] {
            let results = CommandPaletteSearchEngine(entries: searchCorpus).search(
                query: query,
                resultLimit: resultLimit,
                historyBoost: scoreBoost ?? { _, _ in 0 },
                shouldCancel: shouldCancel
            )

            return results.map { result in
                CommandPaletteResolvedSearchMatch(
                    commandID: result.payload,
                    score: result.score,
                    titleMatchIndices: result.titleMatchIndices
                )
            }
        }

        if let results = searchIndex?.search(
            query: query,
            resultLimit: nucleoResultLimit,
            historyBoost: scoreBoost,
            shouldCancel: shouldCancel
        ) {
            let nucleoMatches = results.map { result in
                CommandPaletteResolvedSearchMatch(
                    commandID: result.payload,
                    score: result.score,
                    titleMatchIndices: result.titleMatchIndices
                )
            }
            if Self.shouldConsiderSwiftSingleEditFallback(
                preparedQuery: preparedQuery,
                queryIsEmpty: queryIsEmpty,
                limit: nucleoResultLimit
            ) {
                let searchCorpusByID = providedSearchCorpusByID ?? Self.searchCorpusByID(searchCorpus)
                guard Self.shouldIncludeSwiftSingleEditFallback(
                    preparedQuery: preparedQuery,
                    nucleoMatches: nucleoMatches,
                    searchCorpusByID: searchCorpusByID
                ) else {
                    return nucleoMatches
                }
                let fallbackMatches = Self.swiftSingleEditFallbackMatches(
                    swiftSearchMatches(),
                    preparedQuery: preparedQuery,
                    searchCorpusByID: searchCorpusByID
                )
                guard !fallbackMatches.isEmpty else {
                    return nucleoMatches
                }
                return Self.mergedSwiftFallbackMatches(
                    fallbackMatches,
                    nucleoMatches: nucleoMatches,
                    searchCorpusByID: searchCorpusByID,
                    limit: nucleoResultLimit
                )
            }
            return nucleoMatches
        }

        return swiftSearchMatches()
    }

    private static func searchCorpusByID(
        _ searchCorpus: [CommandPaletteSearchCorpusEntry<String>]
    ) -> [String: CommandPaletteSearchCorpusEntry<String>] {
        firstValueDictionary(searchCorpus, keyedBy: \.payload)
    }

    private static func shouldConsiderSwiftSingleEditFallback(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        queryIsEmpty: Bool,
        limit: Int
    ) -> Bool {
        guard limit > 0 else { return false }
        guard !queryIsEmpty else { return false }
        return preparedQuery.tokens.contains(where: { $0.allowsSingleEdit })
    }

    private static func shouldIncludeSwiftSingleEditFallback(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        nucleoMatches: [CommandPaletteResolvedSearchMatch],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>]
    ) -> Bool {
        guard !nucleoMatches.isEmpty else { return true }
        let singleEditTokens = preparedQuery.tokens.filter { $0.allowsSingleEdit }

        let probedMatches = nucleoMatches.prefix(singleEditFallbackNucleoProbeLimit)
        return singleEditTokens.contains { token in
            !probedMatches.contains { match in
                guard let entry = searchCorpusByID[match.commandID] else { return false }
                return entry.preparedSearchableTexts.contains {
                    CommandPaletteFuzzyMatcher.tokenCanMatchWithoutSingleEdit(
                        token,
                        preparedCandidate: $0
                    )
                }
            }
        }
    }

    private static func swiftSingleEditFallbackMatches(
        _ swiftMatches: [CommandPaletteResolvedSearchMatch],
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>]
    ) -> [CommandPaletteResolvedSearchMatch] {
        swiftMatches.filter { match in
            guard let entry = searchCorpusByID[match.commandID] else { return false }
            return CommandPaletteFuzzyMatcher.usesSingleEditWordPrefix(
                preparedQuery: preparedQuery,
                preparedCandidates: entry.preparedSearchableTexts
            )
        }
    }

    /// Internal (not private) so package tests can exercise the merge directly.
    static func mergedSwiftFallbackMatches(
        _ swiftMatches: [CommandPaletteResolvedSearchMatch],
        nucleoMatches: [CommandPaletteResolvedSearchMatch],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        limit: Int
    ) -> [CommandPaletteResolvedSearchMatch] {
        guard limit > 0 else { return [] }
        var matchesByID: [String: CommandPaletteResolvedSearchMatch] = [:]
        matchesByID.reserveCapacity(swiftMatches.count + nucleoMatches.count)

        func merge(_ match: CommandPaletteResolvedSearchMatch) {
            if let existing = matchesByID[match.commandID] {
                if resolvedSearchMatchIsBetter(match, than: existing, searchCorpusByID: searchCorpusByID) {
                    matchesByID[match.commandID] = match
                }
                return
            }
            matchesByID[match.commandID] = match
        }

        for match in nucleoMatches {
            merge(match)
        }
        for match in swiftMatches {
            merge(match)
        }

        return Array(
            matchesByID.values
                .sorted {
                    resolvedSearchMatchIsBetter($0, than: $1, searchCorpusByID: searchCorpusByID)
                }
                .prefix(limit)
        )
    }

    private static func resolvedSearchMatchIsBetter(
        _ lhs: CommandPaletteResolvedSearchMatch,
        than rhs: CommandPaletteResolvedSearchMatch,
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>]
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsEntry = searchCorpusByID[lhs.commandID]
        let rhsEntry = searchCorpusByID[rhs.commandID]
        let lhsRank = lhsEntry?.rank ?? Int.max
        let rhsRank = rhsEntry?.rank ?? Int.max
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsTitle = lhsEntry?.title ?? lhs.commandID
        let rhsTitle = rhsEntry?.title ?? rhs.commandID
        let titleComparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.commandID < rhs.commandID
    }

    /// Resolves preview matches: full-corpus search for the commands scope,
    /// candidate-restricted Swift search for the switcher scope.
    public func previewSearchMatches(
        scope: CommandPaletteListScope,
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        additionalScoreBoost: ((String, Bool) -> Int)? = nil,
        resultLimit: Int
    ) -> [CommandPaletteResolvedSearchMatch] {
        guard resultLimit > 0 else {
            return []
        }

        if scope == .commands {
            return resolvedSearchMatches(
                searchIndex: searchIndex,
                searchCorpus: searchCorpus,
                searchCorpusByID: searchCorpusByID,
                query: query,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                additionalScoreBoost: additionalScoreBoost,
                resultLimit: resultLimit
            )
        }

        guard !candidateCommandIDs.isEmpty else {
            return []
        }

        var seenCommandIDs: Set<String> = []
        let previewEntries: [CommandPaletteSearchCorpusEntry<String>] = candidateCommandIDs.compactMap { commandID in
            guard seenCommandIDs.insert(commandID).inserted else { return nil }
            return searchCorpusByID[commandID]
        }
        guard !previewEntries.isEmpty else {
            return []
        }

        return resolvedSearchMatches(
            searchIndex: nil,
            searchCorpus: previewEntries,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp,
            additionalScoreBoost: additionalScoreBoost,
            resultLimit: resultLimit
        )
    }

    /// Truncates `resultIDs` to `limit` preview candidates.
    public static func previewCandidateCommandIDs(
        resultIDs: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        guard resultIDs.count > limit else { return resultIDs }
        return Array(resultIDs.prefix(limit))
    }

    /// Whether opening the palette should seed results synchronously instead
    /// of waiting for the async search task.
    public static func shouldSynchronouslySeedResults(
        hasVisibleResultsForScope: Bool,
        hasSearchIndex: Bool,
        corpusCount: Int
    ) -> Bool {
        !hasVisibleResultsForScope && (hasSearchIndex || corpusCount <= synchronousSeedCorpusLimit)
    }

    /// Whether the visible empty state should be preserved while a search is
    /// pending, to avoid flashing stale results.
    public static func shouldPreserveEmptyStateWhileSearchPending(
        isSearchPending: Bool,
        visibleResultsScopeMatches: Bool,
        resolvedSearchScopeMatches: Bool,
        resolvedSearchFingerprintMatches: Bool,
        resolvedResultsAreEmpty: Bool
    ) -> Bool {
        guard isSearchPending,
              visibleResultsScopeMatches,
              resolvedSearchScopeMatches,
              resolvedSearchFingerprintMatches,
              resolvedResultsAreEmpty else {
            return false
        }

        return true
    }

    /// Recency/frequency boost for `commandId`; reduced to a third when the
    /// query is non-empty.
    public static func historyBoost(
        for commandId: String,
        queryIsEmpty: Bool,
        history: [String: CommandPaletteUsageEntry],
        now: TimeInterval
    ) -> Int {
        guard let entry = history[commandId] else { return 0 }

        let ageDays = max(0, now - entry.lastUsedAt) / 86_400
        let recencyBoost = max(0, 320 - Int(ageDays * 20))
        let countBoost = min(180, entry.useCount * 12)
        let totalBoost = recencyBoost + countBoost

        return queryIsEmpty ? totalBoost : max(0, totalBoost / 3)
    }
}
