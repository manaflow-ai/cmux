import Foundation

/// Small deterministic fuzzy scorer for artifact basenames and relative paths.
struct ArtifactFuzzyMatcher: Sendable {
    func score(candidate: String, query: String) -> Int? {
        let candidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty else { return 0 }
        if candidate == query { return 10_000 }
        if let range = candidate.range(of: query) {
            let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return 8_000 - min(offset, 1_000) - max(0, candidate.count - query.count)
        }
        var candidateIndex = candidate.startIndex
        var score = 0
        var previousMatch: String.Index?
        for queryCharacter in query {
            guard let match = candidate[candidateIndex...].firstIndex(of: queryCharacter) else { return nil }
            let gap = candidate.distance(from: candidateIndex, to: match)
            score += previousMatch.map { candidate.index(after: $0) == match ? 30 : 8 } ?? 15
            score -= min(gap, 20)
            previousMatch = match
            candidateIndex = candidate.index(after: match)
        }
        return score - max(0, candidate.count - query.count)
    }
}
