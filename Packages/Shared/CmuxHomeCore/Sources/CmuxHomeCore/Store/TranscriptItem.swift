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

    public var id: IdempotencyKey { key }

    public var plainText: String { parts.map(\.plainText).joined(separator: "\n") }
}

public enum TranscriptDerivation {
    /// Mirror window + pending sends for one conversation, in display order.
    public static func items(window: TranscriptWindow?, pending: [PendingIntent], me: ParticipantID) -> [TranscriptItem] {
        var items: [TranscriptItem] = (window?.messages ?? []).map { message in
            TranscriptItem(
                key: message.clientMessageID,
                seq: message.seq,
                author: message.author,
                parts: message.isRetracted ? [] : message.parts,
                createdAt: message.createdAt,
                delivery: .committed,
                reactions: message.reactions,
                isRetracted: message.isRetracted
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
