/// The retained conversation plus a summary of compaction work.
public struct ConversationCompaction: Equatable, Sendable {
    /// Ordered turns retained for the handoff.
    public let turns: [ConversationTurn]
    /// Number of eligible turns omitted entirely.
    public let omittedTurnCount: Int
    /// Number of retained turns shortened to fit the budget.
    public let shortenedTurnCount: Int

    /// Creates a compaction result.
    /// - Parameters:
    ///   - turns: Ordered turns retained for the handoff.
    ///   - omittedTurnCount: Number of eligible turns omitted entirely.
    ///   - shortenedTurnCount: Number of retained turns shortened to fit the budget.
    public init(
        turns: [ConversationTurn],
        omittedTurnCount: Int,
        shortenedTurnCount: Int
    ) {
        self.turns = turns
        self.omittedTurnCount = omittedTurnCount
        self.shortenedTurnCount = shortenedTurnCount
    }
}
