/// Formats a compacted conversation into one target-harness message.
public protocol ConversationFormatting: Sendable {
    /// Returns a safe UTF-8 byte-cost bound for one turn, including role framing.
    /// - Parameter turn: The turn whose formatted cost should be measured.
    /// - Returns: An upper bound on the bytes the turn contributes to the formatted prompt.
    func formattedByteCount(of turn: ConversationTurn) -> Int

    /// Formats compacted turns into one bounded handoff prompt.
    /// - Parameters:
    ///   - compaction: Retained turns and compaction statistics.
    ///   - sourceDisplayName: User-facing name of the source harness.
    ///   - maximumBytes: Maximum number of UTF-8 bytes in the result.
    /// - Returns: A harness-neutral handoff prompt.
    func format(
        _ compaction: ConversationCompaction,
        sourceDisplayName: String,
        maximumBytes: Int
    ) -> String
}
