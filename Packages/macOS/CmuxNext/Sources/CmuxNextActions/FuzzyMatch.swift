/// Small subsequence scorer for palette search. Higher is better; nil means
/// no match. Rewards prefix and word-boundary hits and contiguous runs.
///
/// Placeholder quality: the palette agent can replace this with a nucleo-style
/// matcher without changing `ActionRegistry.search`.
public enum FuzzyMatch {
    public static func score(_ needle: String, in haystack: String) -> Int? {
        let query = Array(needle.lowercased())
        let text = Array(haystack.lowercased())
        guard !query.isEmpty, query.count <= text.count else { return query.isEmpty ? 0 : nil }

        var score = 0
        var queryIndex = 0
        var previousMatch = -2
        for (textIndex, character) in text.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            score += 1
            if textIndex == 0 { score += 8 }
            if textIndex > 0, text[textIndex - 1] == " " || text[textIndex - 1] == "." { score += 5 }
            if textIndex == previousMatch + 1 { score += 3 }
            previousMatch = textIndex
            queryIndex += 1
        }
        guard queryIndex == query.count else { return nil }
        // Prefer shorter haystacks among equal matches.
        return score * 100 - text.count
    }
}
