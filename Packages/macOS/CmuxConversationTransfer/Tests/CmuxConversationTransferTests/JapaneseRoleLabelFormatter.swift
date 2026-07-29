@testable import CmuxConversationTransfer

struct JapaneseRoleLabelFormatter: ConversationFormatting {
    func format(
        _ compaction: ConversationCompaction,
        sourceDisplayName _: String,
        maximumBytes: Int
    ) -> String {
        var builder = UTF8BoundedStringBuilder(maximumBytes: maximumBytes)
        for turn in compaction.turns {
            builder.append("\n\n")
            builder.appendPromptSafe(label(for: turn.role))
            builder.append(":\n")
            builder.appendPromptSafe(turn.text)
        }
        return builder.value
    }

    func formattedByteCount(of turn: ConversationTurn) -> Int {
        label(for: turn.role).utf8.count + turn.text.utf8.count + 4
    }

    private func label(for role: ConversationRole) -> String {
        switch role {
        case .user:
            "ユーザー"
        case .assistant:
            "アシスタント"
        case .system:
            "システム"
        case .tool:
            "ツール"
        case .event:
            "イベント"
        }
    }
}
