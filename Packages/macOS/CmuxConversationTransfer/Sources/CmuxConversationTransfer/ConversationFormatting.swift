/// Formats a compacted conversation into one target-harness message.
public protocol ConversationFormatting: Sendable {
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
