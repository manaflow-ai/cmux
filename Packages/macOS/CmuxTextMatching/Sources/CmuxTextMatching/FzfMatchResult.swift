/// Where and how well one fzf algorithm matched a pattern in a text.
///
/// Offsets count Unicode scalars from the start of the text, like fzf's runes.
public struct FzfMatchResult: Sendable, Equatable {
    /// Offset of the first matched character, as fzf reports it.
    public let start: Int
    /// Offset one past the last matched character.
    public let end: Int
    /// fzf's score: higher is better.
    public let score: Int
    /// Offsets of every matched character, ascending; empty when positions were not requested
    /// or the algorithm only reports a span.
    public let positions: [Int]

    /// Creates a result.
    ///
    /// - Parameters:
    ///   - start: Offset of the first matched character.
    ///   - end: Offset one past the last matched character.
    ///   - score: The fzf score.
    ///   - positions: Matched character offsets, ascending.
    public init(start: Int, end: Int, score: Int, positions: [Int]) {
        self.start = start
        self.end = end
        self.score = score
        self.positions = positions
    }
}
