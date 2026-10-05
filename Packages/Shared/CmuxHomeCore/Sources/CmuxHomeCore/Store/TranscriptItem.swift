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
    /// The owner's message id of a committed message (nil for a pending
    /// send). Opaque to renderers: hosts pass it back in ops that name a
    /// message (`addReaction`). Filled by the data side (HomeStore).
    public var messageID: MessageID?
    /// Local files for this row's attachment parts, by content hash, when
    /// this client has them (my sends, before and after the echo). Empty
    /// otherwise: fetch the bytes with `HomeStore.fetchAttachment`.
    public var localAttachments: [String: LocalAttachmentFiles]
    /// Upload progress (0...1) by content hash while this send uploads its
    /// attachments. Empty once the uploads end (done or failed).
    public var attachmentProgress: [String: Double]
    /// A "Not Delivered" send that reached the owner and got no answer
    /// after every resend: the owner may have committed it. The host says
    /// "may not have been delivered" instead of "Not Delivered". Retry
    /// sends it again under the same key (the owner applies it once), and
    /// if it was committed the echo turns the row into the message, also
    /// after the user discards it.
    public var mayHaveBeenDelivered = false

    public init(key: IdempotencyKey, seq: Seq?, author: ParticipantID, parts: [MessagePart], createdAt: Date,
                delivery: Delivery, reactions: [Reaction] = [], isRetracted: Bool = false,
                editedAt: Date? = nil, replyTo: PartRef? = nil, threadRoot: MessageID? = nil, messageID: MessageID? = nil,
                localAttachments: [String: LocalAttachmentFiles] = [:], attachmentProgress: [String: Double] = [:]) {
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
        self.messageID = messageID
        self.localAttachments = localAttachments
        self.attachmentProgress = attachmentProgress
    }

    /// Hashes of this row's attachment parts, in part order.
    public var attachmentHashes: [String] {
        parts.compactMap { if case .attachment(let ref) = $0 { ref.hash } else { nil } }
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
                threadRoot: message.threadRoot,
                messageID: message.id
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
            var item = TranscriptItem(
                key: entry.intent.key,
                seq: nil,
                author: me,
                parts: parts,
                createdAt: entry.intent.issuedAt,
                delivery: delivery,
                reactions: [],
                isRetracted: false
            )
            item.mayHaveBeenDelivered = delivery != .sending && entry.mayHaveBeenDelivered
            items.append(item)
        }
        return items
    }
}
