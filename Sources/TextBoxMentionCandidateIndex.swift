import Foundation

struct TextBoxMentionCandidateIndex: Sendable {
    private static let nucleoProbeLimitMultiplier = 4
    private static let minimumNucleoProbeLimit = 512

    private let corpus: [CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>]
    private let corpusByTargetPath: [String: CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>]
    private let emptyQueryCandidates: [TextBoxMentionCandidate]
    private let nucleoIndex: CommandPaletteNucleoSearchIndex<TextBoxMentionCandidate>?

    init(candidates: [TextBoxMentionCandidate]) {
        let entries = candidates.map { candidate in
            CommandPaletteSearchCorpusEntry(
                payload: candidate,
                rank: candidate.priority,
                title: candidate.title,
                searchableTexts: [
                    candidate.title,
                    candidate.searchKey
                ]
            )
        }
        corpus = entries
        corpusByTargetPath = CommandPaletteSearchOrchestrator.firstValueDictionary(
            entries,
            keyedBy: { $0.payload.targetPath }
        )
        emptyQueryCandidates = entries
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map(\.payload)
        nucleoIndex = entries.count >= 32 ? CommandPaletteNucleoSearchIndex(entries: entries) : nil
    }

    func rankedCandidates(
        matching rawQuery: String,
        limit: Int,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [TextBoxMentionCandidate] {
        guard limit > 0, !shouldCancel() else { return [] }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(emptyQueryCandidates.prefix(limit))
        }

        if let nucleoIndex {
            let probeLimit = Self.nucleoProbeLimit(corpusCount: corpus.count, requestedLimit: limit)
            guard let nucleoResults = nucleoIndex.search(
                query: query,
                resultLimit: probeLimit,
                shouldCancel: shouldCancel
            ) else {
                return Self.swiftRankedCandidates(
                    entries: corpus,
                    query: query,
                    limit: limit,
                    shouldCancel: shouldCancel
                )
            }
            if shouldCancel() { return [] }
            let probedCorpus = nucleoResults.compactMap { result in
                corpusByTargetPath[result.payload.targetPath]
            }
            let swiftMatches = Self.swiftRankedCandidates(
                entries: probedCorpus,
                query: query,
                limit: limit,
                shouldCancel: shouldCancel
            )
            let mayHaveUnprobedNucleoResults = probeLimit < corpus.count &&
                nucleoResults.count >= probeLimit
            guard swiftMatches.count < limit,
                  mayHaveUnprobedNucleoResults else {
                return swiftMatches
            }
            if shouldCancel() { return [] }
            return Self.swiftRankedCandidates(
                entries: corpus,
                query: query,
                limit: limit,
                shouldCancel: shouldCancel
            )
        }

        return Self.swiftRankedCandidates(
            entries: corpus,
            query: query,
            limit: limit,
            shouldCancel: shouldCancel
        )
    }

    private static func nucleoProbeLimit(corpusCount: Int, requestedLimit: Int) -> Int {
        let expandedLimit = requestedLimit * Self.nucleoProbeLimitMultiplier
        return min(corpusCount, max(expandedLimit, Self.minimumNucleoProbeLimit))
    }

    private static func swiftRankedCandidates(
        entries: [CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>],
        query: String,
        limit: Int,
        shouldCancel: @escaping () -> Bool
    ) -> [TextBoxMentionCandidate] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let filteredEntries: [CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>]
        if preparedQuery.isEmpty {
            filteredEntries = entries
        } else {
            var matches: [CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>] = []
            matches.reserveCapacity(min(entries.count, limit))
            for entry in entries {
                if shouldCancel() { return [] }
                if mentionCandidate(entry, matches: preparedQuery) {
                    matches.append(entry)
                }
            }
            if shouldCancel() { return [] }
            filteredEntries = matches
        }
        guard !filteredEntries.isEmpty else { return [] }

        return CommandPaletteSearchEngine.search(
            entries: filteredEntries,
            query: query,
            resultLimit: limit,
            historyBoost: { _, _ in 0 },
            shouldCancel: shouldCancel
        )
        .map(\.payload)
    }

    private static func mentionCandidate(
        _ entry: CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>,
        matches preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery
    ) -> Bool {
        guard !preparedQuery.isEmpty else { return true }
        for token in preparedQuery.tokens {
            var tokenMatchesCandidate = false
            for candidate in entry.preparedSearchableTexts where CommandPaletteFuzzyMatcher
                .tokenCanMatchWithoutSingleEdit(token, preparedCandidate: candidate) {
                tokenMatchesCandidate = true
                break
            }
            if !tokenMatchesCandidate {
                return false
            }
        }
        return true
    }

}
