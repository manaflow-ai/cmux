import Foundation

/// Pure Swift ranking engine over a prepared corpus: scores entries with
/// ``CommandPaletteFuzzyMatcher``, applies history boosts, and returns the
/// top results in deterministic order (score, rank, title, index).
public enum CommandPaletteSearchEngine {
    private static let titleMatchBonus = 2000

    private struct ScoredEntry<Payload>: Sendable where Payload: Sendable {
        let entry: CommandPaletteSearchCorpusEntry<Payload>
        let index: Int
        let score: Int
    }

    private static func scoredEntryIsBetter<Payload: Sendable>(
        _ lhs: ScoredEntry<Payload>,
        than rhs: ScoredEntry<Payload>
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.entry.rank != rhs.entry.rank { return lhs.entry.rank < rhs.entry.rank }
        let titleComparison = lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.index < rhs.index
    }

    private static func scoredEntryIsWorse<Payload: Sendable>(
        _ lhs: ScoredEntry<Payload>,
        than rhs: ScoredEntry<Payload>
    ) -> Bool {
        scoredEntryIsBetter(rhs, than: lhs)
    }

    private static func siftUpWorstScoredEntryHeap<Payload: Sendable>(
        _ heap: inout [ScoredEntry<Payload>],
        from startIndex: Int
    ) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard scoredEntryIsWorse(heap[child], than: heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftDownWorstScoredEntryHeap<Payload: Sendable>(
        _ heap: inout [ScoredEntry<Payload>],
        from startIndex: Int
    ) {
        var parent = startIndex
        while true {
            let leftChild = (parent * 2) + 1
            guard leftChild < heap.count else { return }

            let rightChild = leftChild + 1
            var worstChild = leftChild
            if rightChild < heap.count,
               scoredEntryIsWorse(heap[rightChild], than: heap[leftChild]) {
                worstChild = rightChild
            }

            guard scoredEntryIsWorse(heap[worstChild], than: heap[parent]) else { return }
            heap.swapAt(parent, worstChild)
            parent = worstChild
        }
    }

    private static func appendScoredEntry<Payload: Sendable>(
        _ scoredEntry: ScoredEntry<Payload>,
        to scoredEntries: inout [ScoredEntry<Payload>],
        limit: Int?
    ) {
        guard let limit else {
            scoredEntries.append(scoredEntry)
            return
        }

        if scoredEntries.count < limit {
            scoredEntries.append(scoredEntry)
            siftUpWorstScoredEntryHeap(&scoredEntries, from: scoredEntries.count - 1)
            return
        }

        guard let worstEntry = scoredEntries.first,
              scoredEntryIsBetter(scoredEntry, than: worstEntry) else {
            return
        }
        scoredEntries[0] = scoredEntry
        siftDownWorstScoredEntryHeap(&scoredEntries, from: 0)
    }

    /// Searches `entries` for `query`, boosting each payload by
    /// `historyBoost(payload, queryIsEmpty)`.
    public static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int? = nil,
        historyBoost: (Payload, Bool) -> Int
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            resultLimit: resultLimit,
            historyBoost: historyBoost,
            shouldCancel: nil
        )
    }

    /// Searches with a cooperative cancellation probe checked every 16 entries.
    public static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int? = nil,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: @escaping () -> Bool
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            resultLimit: resultLimit,
            historyBoost: historyBoost,
            shouldCancel: Optional(shouldCancel)
        )
    }

    private static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int?,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: (() -> Bool)?
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        if let resultLimit, resultLimit <= 0 {
            return []
        }
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        let limitedResultCount = resultLimit.map { min($0, entries.count) }
        var scoredEntries: [ScoredEntry<Payload>] = []
        scoredEntries.reserveCapacity(limitedResultCount ?? entries.count)

        func shouldCancelSearch(at index: Int) -> Bool {
            guard let shouldCancel else { return false }
            return index % 16 == 0 && shouldCancel()
        }

        if queryIsEmpty {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                appendScoredEntry(
                    ScoredEntry(
                        entry: entry,
                        index: index,
                        score: historyBoost(entry.payload, true)
                    ),
                    to: &scoredEntries,
                    limit: limitedResultCount
                )
            }
        } else {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                guard let fuzzyScore = weightedScore(
                    preparedQuery: preparedQuery,
                    entry: entry
                ) else {
                    continue
                }
                appendScoredEntry(
                    ScoredEntry(
                        entry: entry,
                        index: index,
                        score: fuzzyScore + historyBoost(entry.payload, false)
                    ),
                    to: &scoredEntries,
                    limit: limitedResultCount
                )
            }
        }

        if shouldCancel?() == true { return [] }

        scoredEntries.sort { scoredEntryIsBetter($0, than: $1) }

        let outputCount = resultLimit.map { min($0, scoredEntries.count) } ?? scoredEntries.count
        var results: [CommandPaletteSearchCorpusResult<Payload>] = []
        results.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            if shouldCancelSearch(at: index) { return [] }
            let scoredEntry = scoredEntries[index]
            let entry = scoredEntry.entry
            let titleMatchIndices: Set<Int>
            if queryIsEmpty {
                titleMatchIndices = []
            } else {
                titleMatchIndices = entry.preparedTitle.map {
                    CommandPaletteFuzzyMatcher.matchCharacterIndices(
                        preparedQuery: preparedQuery,
                        preparedCandidate: $0
                    )
                } ?? []
            }
            results.append(
                CommandPaletteSearchCorpusResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: scoredEntry.score,
                    titleMatchIndices: titleMatchIndices
                )
            )
        }
        return results
    }

    private static func weightedScore<Payload: Sendable>(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        entry: CommandPaletteSearchCorpusEntry<Payload>
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
            preparedQuery: preparedQuery,
            preparedCandidates: entry.preparedSearchableTexts,
            exactCandidateTexts: entry.searchableTextSet,
            wholeCandidatePrefixScoreByToken: entry.searchablePrefixScoreByToken
        ) else {
            return nil
        }
        if let preparedTitle = entry.preparedTitle,
           preparedQuery.tokens.allSatisfy({ $0.couldMatch(preparedTitle) }),
           let titleScore = CommandPaletteFuzzyMatcher.score(
                preparedQuery: preparedQuery,
                preparedCandidate: preparedTitle
            ) {
            return max(fuzzyScore, titleScore + titleMatchBonus)
        }
        return fuzzyScore
    }
}
