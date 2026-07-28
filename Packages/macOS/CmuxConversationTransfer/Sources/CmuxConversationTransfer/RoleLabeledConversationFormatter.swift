import Foundation

/// Produces a human-readable prompt with explicit role labels.
public struct RoleLabeledConversationFormatter: ConversationFormatting {
    /// Creates a role-labeled formatter.
    public init() {}

    /// Formats compacted turns into a sanitized, bounded handoff prompt.
    /// - Parameters:
    ///   - compaction: Retained turns and compaction statistics.
    ///   - sourceDisplayName: User-facing name of the source harness.
    ///   - maximumCharacters: Maximum number of Swift characters in the result.
    /// - Returns: A harness-neutral handoff prompt.
    public func format(
        _ compaction: ConversationCompaction,
        sourceDisplayName: String,
        maximumCharacters: Int
    ) -> String {
        let introductionFormat = String(
            localized: "forkConversation.handoff.introduction",
            defaultValue: "The following conversation was transferred from %@. Continue the latest unfinished request using this context."
        )
        let safeSourceName = String(promptSafe(sourceDisplayName).prefix(80))
        var sections = [String(format: introductionFormat, safeSourceName)]

        if compaction.omittedTurnCount > 0 || compaction.shortenedTurnCount > 0 {
            let compactionFormat = String(
                localized: "forkConversation.handoff.compacted",
                defaultValue: "Conversation compacted: %1$lld earlier turns omitted, %2$lld long turns shortened."
            )
            sections.append(String(
                format: compactionFormat,
                Int64(compaction.omittedTurnCount),
                Int64(compaction.shortenedTurnCount)
            ))
        }

        sections.append(contentsOf: compaction.turns.map { turn in
            "\(roleLabel(turn.role)):\n\(promptSafe(turn.text))"
        })
        return String(sections.joined(separator: "\n\n").prefix(maximumCharacters))
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

    /// Removes terminal control bytes while preserving tabs, newlines, and Unicode text.
    private func promptSafe(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || (scalar.value >= 32 && scalar.value != 127)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
