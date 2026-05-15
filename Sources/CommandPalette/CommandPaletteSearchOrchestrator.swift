import Foundation

enum CommandPaletteListScope: String, Sendable {
    case commands
    case switcher
}

struct CommandPaletteUsageEntry: Codable, Sendable {
    var useCount: Int
    var lastUsedAt: TimeInterval
}

struct CommandPaletteResolvedSearchMatch: Sendable {
    let commandID: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

enum CommandPaletteSearchOrchestrator {
    private static let synchronousSeedCorpusLimit = 256
    private static let singleEditFallbackNucleoProbeLimit = 12

    static let resolvedResultLimit = 100

    static func resolvedSearchMatches(
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        searchCorpusByID providedSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>]? = nil,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        resultLimit: Int? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [CommandPaletteResolvedSearchMatch] {
        let limit = resultLimit ?? resolvedResultLimit
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let historyBoost: ((String, Bool) -> Int)? = usageHistory.isEmpty ? nil : { commandId, queryIsEmpty in
            self.historyBoost(
                for: commandId,
                queryIsEmpty: queryIsEmpty,
                history: usageHistory,
                now: historyTimestamp
            )
        }

        func swiftSearchMatches() -> [CommandPaletteResolvedSearchMatch] {
            let results = CommandPaletteSearchEngine.search(
                entries: searchCorpus,
                query: query,
                resultLimit: limit,
                historyBoost: historyBoost ?? { _, _ in 0 },
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
            resultLimit: limit,
            historyBoost: historyBoost,
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
                limit: limit
            ) {
                let searchCorpusByID = providedSearchCorpusByID ?? Self.searchCorpusByID(searchCorpus)
                guard Self.shouldIncludeSwiftSingleEditFallback(
                    preparedQuery: preparedQuery,
                    nucleoMatches: nucleoMatches,
                    searchCorpusByID: searchCorpusByID
                ) else {
                    return nucleoMatches
                }
                let fallbackMatches = swiftSingleEditFallbackMatches(
                    swiftSearchMatches(),
                    preparedQuery: preparedQuery,
                    searchCorpusByID: searchCorpusByID
                )
                guard !fallbackMatches.isEmpty else {
                    return nucleoMatches
                }
                return mergedSwiftFallbackMatches(
                    fallbackMatches,
                    nucleoMatches: nucleoMatches,
                    limit: limit
                )
            }
            return nucleoMatches
        }

        return swiftSearchMatches()
    }

    private static func searchCorpusByID(
        _ searchCorpus: [CommandPaletteSearchCorpusEntry<String>]
    ) -> [String: CommandPaletteSearchCorpusEntry<String>] {
        var entriesByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
        entriesByID.reserveCapacity(searchCorpus.count)
        for entry in searchCorpus where entriesByID[entry.payload] == nil {
            entriesByID[entry.payload] = entry
        }
        return entriesByID
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

    private static func mergedSwiftFallbackMatches(
        _ swiftMatches: [CommandPaletteResolvedSearchMatch],
        nucleoMatches: [CommandPaletteResolvedSearchMatch],
        limit: Int
    ) -> [CommandPaletteResolvedSearchMatch] {
        guard limit > 0 else { return [] }
        var merged: [CommandPaletteResolvedSearchMatch] = []
        merged.reserveCapacity(min(limit, swiftMatches.count + nucleoMatches.count))
        var seenCommandIDs: Set<String> = []

        for match in swiftMatches {
            guard seenCommandIDs.insert(match.commandID).inserted else { continue }
            merged.append(match)
            if merged.count == limit { return merged }
        }
        for match in nucleoMatches {
            guard seenCommandIDs.insert(match.commandID).inserted else { continue }
            merged.append(match)
            if merged.count == limit { return merged }
        }
        return merged
    }

    static func previewSearchMatches(
        scope: CommandPaletteListScope,
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
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
            resultLimit: resultLimit
        )
    }

    static func commandPreviewMatchCommandIDsForTests(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        resultLimit: Int
    ) -> [String] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        return previewSearchMatches(
            scope: .commands,
            searchIndex: searchIndex,
            searchCorpus: searchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: searchCorpusByID,
            query: query,
            usageHistory: [:],
            queryIsEmpty: preparedQuery.isEmpty,
            historyTimestamp: 0,
            resultLimit: resultLimit
        ).map(\.commandID)
    }

    static func previewCandidateCommandIDs(
        resultIDs: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        guard resultIDs.count > limit else { return resultIDs }
        return Array(resultIDs.prefix(limit))
    }

    static func shouldSynchronouslySeedResults(
        hasVisibleResultsForScope: Bool,
        hasSearchIndex: Bool,
        corpusCount: Int
    ) -> Bool {
        !hasVisibleResultsForScope && (hasSearchIndex || corpusCount <= synchronousSeedCorpusLimit)
    }

    static func shouldPreserveEmptyStateWhileSearchPending(
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

    static func historyBoost(
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
