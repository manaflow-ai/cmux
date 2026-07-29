import Foundation

/// Produces a human-readable prompt with explicit role labels.
public struct RoleLabeledConversationFormatter: ConversationFormatting {
    /// Creates a role-labeled formatter.
    public init() {}

    /// Returns a safe UTF-8 byte-cost bound for a role-labeled turn.
    /// - Parameter turn: The turn whose role label and text should be measured.
    /// - Returns: An upper bound for the separators, role label, and sanitized text.
    public func formattedByteCount(of turn: ConversationTurn) -> Int {
        let framingByteCount = roleLabel(turn.role).utf8.count + 4
        let total = turn.text.utf8.count.addingReportingOverflow(framingByteCount)
        return total.overflow ? .max : total.partialValue
    }

    /// Formats compacted turns into a sanitized, bounded handoff prompt.
    /// - Parameters:
    ///   - compaction: Retained turns and compaction statistics.
    ///   - sourceDisplayName: User-facing name of the source harness.
    ///   - maximumBytes: Maximum number of UTF-8 bytes in the result.
    /// - Returns: A harness-neutral handoff prompt.
    public func format(
        _ compaction: ConversationCompaction,
        sourceDisplayName: String,
        maximumBytes: Int
    ) -> String {
        let introductionFormat = String(
            localized: "forkConversation.handoff.introduction",
            defaultValue: "The following conversation was transferred from %@. Continue the latest unfinished request using this context."
        )
        var sourceNameBuilder = UTF8BoundedStringBuilder(maximumBytes: 80)
        sourceNameBuilder.appendPromptSafe(sourceDisplayName)
        var builder = UTF8BoundedStringBuilder(maximumBytes: maximumBytes)
        builder.appendPromptSafe(String(format: introductionFormat, sourceNameBuilder.value))

        if compaction.omittedTurnCount > 0 || compaction.shortenedTurnCount > 0 {
            let compactionFormat = String(
                localized: "forkConversation.handoff.compacted",
                defaultValue: "Conversation compacted: %1$lld earlier turns omitted, %2$lld long turns shortened."
            )
            builder.append("\n\n")
            builder.appendPromptSafe(String(
                format: compactionFormat,
                Int64(compaction.omittedTurnCount),
                Int64(compaction.shortenedTurnCount)
            ))
        }

        for turn in compaction.turns {
            builder.append("\n\n")
            builder.appendPromptSafe(roleLabel(turn.role))
            builder.append(":\n")
            builder.appendPromptSafe(turn.text)
        }
        return builder.value
    }

    private func roleLabel(_ role: ConversationRole) -> String {
        switch role {
        case .user:
            String(localized: "forkConversation.handoff.role.user", defaultValue: "User")
        case .assistant:
            String(localized: "forkConversation.handoff.role.assistant", defaultValue: "Assistant")
        case .system:
            String(localized: "forkConversation.handoff.role.system", defaultValue: "System")
        case .tool:
            String(localized: "forkConversation.handoff.role.tool", defaultValue: "Tool")
        case .event:
            String(localized: "forkConversation.handoff.role.event", defaultValue: "Event")
        }
    }
}
