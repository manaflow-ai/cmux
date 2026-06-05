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
                    candidate.subtitle,
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

        if let nucleoIndex,
           let nucleoResults = nucleoIndex.search(
               query: query,
               resultLimit: Self.nucleoProbeLimit(corpusCount: corpus.count, requestedLimit: limit),
               shouldCancel: shouldCancel
           ) {
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
            return Self.mergedRankedCandidates(
                swiftMatches,
                nucleoMatches: nucleoResults.map(\.payload),
                limit: limit
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
        CommandPaletteSearchEngine.search(
            entries: entries,
            query: query,
            resultLimit: limit,
            historyBoost: { _, _ in 0 },
            shouldCancel: shouldCancel
        )
        .map(\.payload)
    }

    private static func mergedRankedCandidates(
        _ swiftMatches: [TextBoxMentionCandidate],
        nucleoMatches: [TextBoxMentionCandidate],
        limit: Int
    ) -> [TextBoxMentionCandidate] {
        var merged: [TextBoxMentionCandidate] = []
        var seenTargetPaths = Set<String>()
        merged.reserveCapacity(min(limit, swiftMatches.count + nucleoMatches.count))

        func append(_ candidate: TextBoxMentionCandidate) {
            guard merged.count < limit,
                  seenTargetPaths.insert(candidate.targetPath).inserted else {
                return
            }
            merged.append(candidate)
        }

        for candidate in swiftMatches {
            append(candidate)
        }
        for candidate in nucleoMatches {
            append(candidate)
        }
        return merged
    }
}
