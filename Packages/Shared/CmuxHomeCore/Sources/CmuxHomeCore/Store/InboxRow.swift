public import Foundation

/// One row of the Home conversation list, derived from mirror + intents.
public struct InboxRow: Hashable, Sendable, Identifiable {
    public var summary: ConversationSummary
    public var kind: ConversationSummary.Kind
    public var title: String
    /// Preview of the newest message (a pending send wins over the mirror).
    public var preview: String
    public var previewAuthor: String?
    public var timestamp: Date
    public var unread: Int
    public var isPinned: Bool
    public var isSending: Bool
    public var hasFailedSend: Bool
    public var isTyping: Bool

    public var id: ConversationID { summary.id }
}

/// Pure derivation and ordering of the conversation list.
public enum InboxOrdering {
    /// Pinned first (by rank), then newest activity first. Ties break on id so
    /// the order is total and stable across derivations.
    public static func ordered(_ rows: [InboxRow]) -> [InboxRow] {
        rows.sorted { left, right in
            switch (left.summary.pinRank, right.summary.pinRank) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if left.timestamp != right.timestamp { return left.timestamp > right.timestamp }
                return left.id.rawValue < right.id.rawValue
            }
        }
    }

    /// Builds rows from the mirror, overlaid with the intent log (pending sends,
    /// pin/mute and read-cursor intents).
    public static func rows(
        mirror: HomeMirror,
        log: IntentLog,
        typing: Set<ConversationID> = []
    ) -> [InboxRow] {
        guard let me = mirror.me?.id else { return [] }
        var summaries = mirror.conversations
        var pendingSend: [ConversationID: PendingIntent] = [:]
        var failed: Set<ConversationID> = []
        for entry in log.entries {
            switch entry.intent.op {
            case .setPinned(let id, let rank):
                summaries[id]?.pinRank = rank
            case .setMuted(let id, let muted):
                summaries[id]?.muted = muted
            case .setReadCursor(let id, let seq):
                if let current = summaries[id]?.readCursors[me], current >= seq { break }
                summaries[id]?.readCursors[me] = seq
            case .sendMessage(let id, _):
                if case .failed = entry.state { failed.insert(id) }
                pendingSend[id] = entry
            default:
                break
            }
        }
        let rows = summaries.values.map { summary -> InboxRow in
            let pending = pendingSend[summary.id]
            var preview = summary.lastMessage?.isRetracted == true ? "" : (summary.lastMessage?.plainText ?? "")
            var author = summary.lastMessage.flatMap { message in
                summary.participants.first { $0.id == message.author }?.displayName
            }
            var timestamp = summary.lastMessage?.createdAt ?? summary.updatedAt
            if let pending, case .sendMessage(_, let parts) = pending.intent.op {
                preview = parts.map(\.plainText).joined(separator: "\n")
                author = mirror.me?.displayName
                timestamp = max(timestamp, pending.intent.issuedAt)
            }
            return InboxRow(
                summary: summary,
                kind: summary.kind(me: me),
                title: summary.displayTitle(me: me),
                preview: preview,
                previewAuthor: author,
                timestamp: timestamp,
                unread: summary.muted ? 0 : summary.unreadCount(me: me),
                isPinned: summary.pinRank != nil,
                isSending: pending.map { if case .failed = $0.state { false } else { true } } ?? false,
                hasFailedSend: failed.contains(summary.id),
                isTyping: typing.contains(summary.id)
            )
        }
        return ordered(rows)
    }
}
