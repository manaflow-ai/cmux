/// How an fzf query matched one text: its total score and the characters to highlight.
public struct FzfQueryMatch: Sendable, Equatable {
    /// The sum of the scores of the terms that matched; higher is better.
    public let score: Int
    /// Unicode-scalar offsets of the matched characters, ascending and without duplicates.
    public let positions: [Int]

    /// Creates a match.
    ///
    /// - Parameters:
    ///   - score: The total score.
    ///   - positions: Matched scalar offsets, ascending and unique.
    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}
