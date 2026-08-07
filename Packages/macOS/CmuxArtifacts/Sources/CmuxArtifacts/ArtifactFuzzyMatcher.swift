import Foundation

/// Small deterministic fuzzy scorer for artifact basenames and relative paths.
struct ArtifactFuzzyMatcher: Sendable {
    static let maximumQueryBytes = 512

    let contentQuery: String
    private let normalizedQuery: String

    init(query rawQuery: String) {
        contentQuery = String(decoding: rawQuery.utf8.prefix(Self.maximumQueryBytes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedQuery = contentQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    var isEmpty: Bool { normalizedQuery.isEmpty }

    func score(candidate: String) -> Int? {
        let candidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedQuery.isEmpty else { return 0 }
        if candidate == normalizedQuery { return 10_000 }
        if let range = candidate.range(of: normalizedQuery) {
            let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return 8_000 - min(offset, 1_000) - max(0, candidate.count - normalizedQuery.count)
        }
        var candidateIndex = candidate.startIndex
        var score = 0
        var previousMatch: String.Index?
        for queryCharacter in normalizedQuery {
            guard let match = candidate[candidateIndex...].firstIndex(of: queryCharacter) else { return nil }
            let gap = candidate.distance(from: candidateIndex, to: match)
            score += previousMatch.map { candidate.index(after: $0) == match ? 30 : 8 } ?? 15
            score -= min(gap, 20)
            previousMatch = match
            candidateIndex = candidate.index(after: match)
        }
        return score - max(0, candidate.count - normalizedQuery.count)
    }
}
