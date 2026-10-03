public import Foundation

/// One row of a transcript: a committed message, or one of my sends the owner
/// has not confirmed. Stable ids: a pending send's id is its key, and the
/// committed echo carries the same key, so a renderer can morph one into the
/// other without a remove + insert.
public struct TranscriptItem: Hashable, Sendable, Identifiable {
    public enum Delivery: Hashable, Sendable {
        case committed
        case sending
        case notDelivered(HomeRejection)
    }

    public var key: IdempotencyKey
    public var seq: Seq?
    public var author: ParticipantID
    public var parts: [MessagePart]
    public var createdAt: Date
    public var delivery: Delivery
    public var reactions: [Reaction]
    public var isRetracted: Bool
    public var editedAt: Date?
    public var replyTo: PartRef?
    public var threadRoot: MessageID?

    public init(key: IdempotencyKey, seq: Seq?, author: ParticipantID, parts: [MessagePart], createdAt: Date,
                delivery: Delivery, reactions: [Reaction] = [], isRetracted: Bool = false,
                editedAt: Date? = nil, replyTo: PartRef? = nil, threadRoot: MessageID? = nil) {
        self.key = key
        self.seq = seq
        self.author = author
        self.parts = parts
        self.createdAt = createdAt
        self.delivery = delivery
        self.reactions = reactions
        self.isRetracted = isRetracted
        self.editedAt = editedAt
        self.replyTo = replyTo
        self.threadRoot = threadRoot
    }

    public var id: IdempotencyKey { key }

    public var plainText: String { parts.map(\.plainText).joined(separator: "\n") }
}

extension TranscriptWindow {
    /// This window + pending sends for its conversation, in display order.
    public func items(pending: [PendingIntent], me: ParticipantID) -> [TranscriptItem] {
        var items: [TranscriptItem] = messages.map { message in
            TranscriptItem(
                key: message.clientMessageID,
                seq: message.seq,
                author: message.author,
                parts: message.isRetracted ? [] : message.parts,
                createdAt: message.createdAt,
                delivery: .committed,
                reactions: message.reactions,
                isRetracted: message.isRetracted,
                editedAt: message.editedAt,
                replyTo: message.replyTo,
                threadRoot: message.threadRoot
            )
        }
        let committedKeys = Set(items.map(\.key))
        for entry in pending where !committedKeys.contains(entry.intent.key) {
            guard case .sendMessage(_, let parts) = entry.intent.op else { continue }
            let delivery: TranscriptItem.Delivery = if case .failed(let rejection) = entry.state {
                .notDelivered(rejection)
            } else {
                .sending
            }
            items.append(TranscriptItem(
                key: entry.intent.key,
                seq: nil,
                author: me,
                parts: parts,
                createdAt: entry.intent.issuedAt,
                delivery: delivery,
                reactions: [],
                isRetracted: false
            ))
        }
        return items
    }
}
