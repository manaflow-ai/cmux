import Foundation

/// One scored search hit produced by ``CommandPaletteSearchEngine``.
public struct CommandPaletteSearchCorpusResult<Payload>: Sendable where Payload: Sendable {
    /// The matched entry's payload.
    public let payload: Payload
    /// The matched entry's rank.
    public let rank: Int
    /// The matched entry's title.
    public let title: String
    /// Final score including any history boost.
    public let score: Int
    /// Title character indices to highlight.
    public let titleMatchIndices: Set<Int>
}
