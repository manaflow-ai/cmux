/// Converts normalized turns into a bounded set suitable for formatting.
public protocol ConversationCompacting: Sendable {
    /// Compacts normalized turns according to the supplied policy.
    /// - Parameters:
    ///   - turns: Source turns in chronological order.
    ///   - policy: Size and role policy for the handoff.
    ///   - formattedByteCount: Safe formatted byte-cost bound for each retained turn.
    /// - Returns: The retained turns and compaction statistics.
    func compact(
        _ turns: [ConversationTurn],
        policy: ConversationTransferPolicy,
        formattedByteCount: @Sendable (ConversationTurn) -> Int
    ) -> ConversationCompaction
}
