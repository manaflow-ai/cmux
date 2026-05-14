import Foundation

enum CommandPaletteListScope: String {
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
    static let resolvedResultLimit = 100

    static func resolvedSearchMatches(
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        resultLimit: Int? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [CommandPaletteResolvedSearchMatch] {
        let limit = resultLimit ?? resolvedResultLimit
        let historyBoost: ((String, Bool) -> Int)? = usageHistory.isEmpty ? nil : { commandId, queryIsEmpty in
            self.historyBoost(
                for: commandId,
                queryIsEmpty: queryIsEmpty,
                history: usageHistory,
                now: historyTimestamp
            )
        }

        if let results = searchIndex?.search(
            query: query,
            resultLimit: limit,
            historyBoost: historyBoost,
            shouldCancel: shouldCancel
        ) {
            return results.map { result in
                CommandPaletteResolvedSearchMatch(
                    commandID: result.payload,
                    score: result.score,
                    titleMatchIndices: result.titleMatchIndices
                )
            }
        }

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
        hasVisibleResultsForScope: Bool
    ) -> Bool {
        !hasVisibleResultsForScope
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
