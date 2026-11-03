public import Foundation

/// A text send the owner had not committed when the cache was written. It
/// comes back as unconfirmed (resent under its key at the first connection;
/// the owner applies a key once) or, when it had failed, as Not Delivered.
/// Sends with attachments are not kept: their local files are not.
public struct HomeCachedSend: Hashable, Sendable, Codable {
    public var key: IdempotencyKey
    public var conversation: ConversationID
    /// Text parts only (with their mentions).
    public var parts: [MessagePart]
    public var issuedAt: Date
    public var failed: Bool
    /// The thread the send replies in (nil: the conversation itself).
    public var threadRoot: MessageID?
    /// The message of the thread it answers (nil: the root; HomeOp.sendMessage `parent`).
    public var parent: MessageID?

    public init(key: IdempotencyKey, conversation: ConversationID, parts: [MessagePart], issuedAt: Date, failed: Bool,
                threadRoot: MessageID? = nil, parent: MessageID? = nil) {
        self.key = key
        self.conversation = conversation
        self.threadRoot = threadRoot
        self.parent = parent
        self.parts = parts
        self.issuedAt = issuedAt
        self.failed = failed
    }

    public init(key: IdempotencyKey, conversation: ConversationID, text: String, issuedAt: Date, failed: Bool) {
        self.init(key: key, conversation: conversation, parts: [.text(text)], issuedAt: issuedAt, failed: failed)
    }

    /// The cached form of a logged send, nil for one the cache does not keep
    /// (acknowledged, still uploading, or with a non-text part).
    init?(_ entry: PendingIntent) {
        guard case .sendMessage(let conversation, let parts, let threadRoot, let parent) = entry.intent.op, !entry.isUploading,
              parts.allSatisfy({ if case .text = $0 { true } else { false } }) else { return nil }
        if case .acknowledged = entry.state { return nil }
        let failed = if case .failed = entry.state { true } else { false }
        self.init(key: entry.intent.key, conversation: conversation, parts: parts, issuedAt: entry.intent.issuedAt, failed: failed,
                  threadRoot: threadRoot, parent: parent)
    }

    /// The intent this send restores into the log.
    var intent: HomeIntent {
        HomeIntent(key: key, op: .sendMessage(conversation: conversation, parts: parts, threadRoot: threadRoot, parent: parent), issuedAt: issuedAt)
    }
}
