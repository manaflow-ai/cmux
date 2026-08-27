import Foundation

// Sendable is safe here because the Swift payload entries are immutable, the
// raw index pointer is destroyed only in deinit, and Rust keeps per-thread
// matcher scratch state outside the immutable index.
/// Immutable nucleo FFI search index over a prepared corpus.
public final class CommandPaletteNucleoSearchIndex<Payload>: @unchecked Sendable where Payload: Sendable {
    private let library: CommandPaletteNucleoSearchLibrary
    private let pointer: OpaquePointer
    private let entries: [CommandPaletteSearchCorpusEntry<Payload>]

    /// Builds an index over `entries`, or returns nil when the FFI dylib is
    /// unavailable or index creation fails.
    public init?(entries: [CommandPaletteSearchCorpusEntry<Payload>]) {
        guard let library = CommandPaletteNucleoSearchLibrary.shared,
              let pointer = library.createIndex(entries: entries) else {
            return nil
        }
        self.library = library
        self.pointer = pointer
        self.entries = entries
    }

    deinit {
        library.destroy(index: pointer)
    }

    /// Searches the index; returns nil when the FFI call fails (callers fall
    /// back to the Swift engine), or an empty array when cancelled.
    public func search(
        query: String,
        resultLimit: Int,
        historyBoost: ((Payload, Bool) -> Int)? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> [CommandPaletteNucleoSearchResult<Payload>]? {
        guard resultLimit > 0 else { return [] }
        if shouldCancel() { return [] }

        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        let boosts: [Int32]?
        if let historyBoost {
            var values: [Int32] = []
            values.reserveCapacity(entries.count)
            var hasNonZeroBoost = false
            for entry in entries {
                let boost = Int32(clamping: historyBoost(entry.payload, queryIsEmpty))
                hasNonZeroBoost = hasNonZeroBoost || boost != 0
                values.append(boost)
            }
            boosts = hasNonZeroBoost ? values : nil
        } else {
            boosts = nil
        }
        guard let rawMatches = library.search(
            index: pointer,
            query: query,
            resultLimit: min(resultLimit, entries.count),
            boosts: boosts
        ) else {
            return nil
        }
        if shouldCancel() { return [] }

        var results: [CommandPaletteNucleoSearchResult<Payload>] = []
        results.reserveCapacity(rawMatches.count)
        for rawMatch in rawMatches {
            guard entries.indices.contains(rawMatch.index) else { continue }
            let entry = entries[rawMatch.index]
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
                CommandPaletteNucleoSearchResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: Self.clampedRoundedScore(rawMatch.score),
                    titleMatchIndices: titleMatchIndices
                )
            )
        }
        return results
    }

    private static func clampedRoundedScore(_ score: Double) -> Int {
        let rounded = score.rounded()
        guard rounded.isFinite else {
            if rounded == .infinity { return Int.max }
            if rounded == -.infinity { return Int.min }
            return 0
        }
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }
}
