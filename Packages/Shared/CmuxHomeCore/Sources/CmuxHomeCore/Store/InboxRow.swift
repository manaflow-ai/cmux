public import Foundation

/// One row of the Home conversation list, derived from mirror + intents.
public struct InboxRow: Hashable, Sendable, Identifiable {
    public var summary: ConversationSummary
    public var kind: ConversationSummary.Kind
    public var title: String
    /// Preview text of the newest message (a pending send wins over the
    /// mirror), without its attachments: empty for an attachment-only message.
    public var preview: String
    /// The newest message's attachments, for a localized label ("2 photos").
    public var previewAttachments: AttachmentPreview?
    public var previewAuthor: String?
    public var timestamp: Date
    public var unread: Int
    public var isPinned: Bool
    public var isSending: Bool
    public var hasFailedSend: Bool
    public var isTyping: Bool

    public var id: ConversationID { summary.id }
}

extension Array where Element == InboxRow {
    /// Pinned first (by rank), then newest activity first. Ties break on id so
    /// the order is total and stable across derivations.
    public func orderedForInbox() -> [InboxRow] {
        sorted { left, right in
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

}

extension HomeMirror {
    /// The conversation list: the mirror overlaid with the intent log
    /// (pending sends, pin/mute and read-cursor intents), in inbox order.
    public func inboxRows(log: IntentLog, typing: Set<ConversationID> = []) -> [InboxRow] {
        let mirror = self
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
            let last = summary.lastMessage?.isRetracted == true ? nil : summary.lastMessage
            var preview = last.map { Self.previewText($0.parts) } ?? ""
            var attachments: AttachmentPreview? = if let last {
                AttachmentPreview.of(last.parts)
            } else if summary.lastMessage == nil {
                summary.previewAttachments
            } else {
                nil
            }
            var author = summary.lastMessage.flatMap { message in
                summary.participants.first { $0.id == message.author }?.displayName
            }
            var timestamp = summary.lastMessage?.createdAt ?? summary.updatedAt
            if let pending, case .sendMessage(_, let parts) = pending.intent.op {
                preview = Self.previewText(parts)
                attachments = AttachmentPreview.of(parts)
                author = mirror.me?.displayName
                timestamp = max(timestamp, pending.intent.issuedAt)
            }
            return InboxRow(
                summary: summary,
                kind: summary.kind(me: me),
                title: summary.displayTitle(me: me),
                preview: preview,
                previewAttachments: attachments,
                previewAuthor: author,
                timestamp: timestamp,
                unread: summary.muted ? 0 : summary.unreadCount(me: me),
                isPinned: summary.pinRank != nil,
                isSending: pending.map { if case .failed = $0.state { false } else { true } } ?? false,
                hasFailedSend: failed.contains(summary.id),
                isTyping: typing.contains(summary.id)
            )
        }
        return rows.orderedForInbox()
    }

    /// The text of every part but attachments (the owner's preview rule).
    static func previewText(_ parts: [MessagePart]) -> String {
        parts.compactMap { if case .attachment = $0 { nil } else { $0.plainText } }.joined(separator: "\n")
    }
}
