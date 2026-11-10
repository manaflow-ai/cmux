public import Foundation

/// A send the owner had not committed when the cache was written. A text send comes back as
/// unconfirmed (resent under its key at the first connection; the owner applies a key once) or,
/// when it had failed, as Not Delivered. A send with attachments keeps its local files (`files`,
/// in the blob cache, which the prune keeps) and comes back as Not Delivered with its upload job
/// rebuilt from them, whatever state it was in (uploading, sent, unanswered, failed): Retry uploads
/// what is missing, or resends under its key and uploads again after an `unknown_attachment`.
public struct HomeCachedSend: Hashable, Sendable, Codable {
    public var key: IdempotencyKey
    public var conversation: ConversationID
    /// Text parts (with their mentions) and attachment parts.
    public var parts: [MessagePart]
    public var issuedAt: Date
    public var failed: Bool
    /// The thread the send replies in (nil: the conversation itself).
    public var threadRoot: MessageID?
    /// The message of the thread it answers (nil: the root; HomeOp.sendMessage `parent`).
    public var parent: MessageID?
    /// The local files of its attachments, one per hash in part order (nil: a text send).
    public var files: [HomeCachedDraftAttachment]?
    /// Whether `message.send` went to the owner (nil: a text send, or a cache before this field).
    public var reachedOwner: Bool?

    public init(key: IdempotencyKey, conversation: ConversationID, parts: [MessagePart], issuedAt: Date, failed: Bool,
                threadRoot: MessageID? = nil, parent: MessageID? = nil,
                files: [HomeCachedDraftAttachment]? = nil, reachedOwner: Bool? = nil) {
        self.key = key
        self.conversation = conversation
        self.threadRoot = threadRoot
        self.parent = parent
        self.parts = parts
        self.issuedAt = issuedAt
        self.failed = failed
        self.files = files
        self.reachedOwner = reachedOwner
    }

    public init(key: IdempotencyKey, conversation: ConversationID, text: String, issuedAt: Date, failed: Bool) {
        self.init(key: key, conversation: conversation, parts: [.text(text)], issuedAt: issuedAt, failed: failed)
    }

    /// The cached form of a logged send, nil for one the cache does not keep: acknowledged, a text
    /// send still uploading (none is), or with a part other than text and attachments. A send with
    /// attachments is kept in every state with its upload job's files (`upload`), as Not Delivered.
    init?(_ entry: PendingIntent, upload: HomeStore.UploadJob? = nil) {
        guard case .sendMessage(let conversation, let parts, let threadRoot, let parent) = entry.intent.op else { return nil }
        if case .acknowledged = entry.state { return nil }
        let textOnly = parts.allSatisfy { if case .text = $0 { true } else { false } }
        let failed = if case .failed = entry.state { true } else { false }
        if textOnly {
            guard !entry.isUploading else { return nil }
            self.init(key: entry.intent.key, conversation: conversation, parts: parts, issuedAt: entry.intent.issuedAt, failed: failed,
                      threadRoot: threadRoot, parent: parent)
            return
        }
        let textAndFiles = parts.allSatisfy {
            switch $0 {
            case .text, .attachment: true
            default: false
            }
        }
        // Without its files (no job: a restored send whose files the blob cache lost) it is kept
        // only when it reached the owner, which holds its uploads until they are swept.
        guard textAndFiles, upload != nil || entry.mayHaveBeenDelivered else { return nil }
        self.init(key: entry.intent.key, conversation: conversation, parts: parts, issuedAt: entry.intent.issuedAt, failed: true,
                  threadRoot: threadRoot, parent: parent,
                  files: upload.map { $0.attachments.map(HomeCachedDraftAttachment.init) },
                  reachedOwner: upload?.reachedOwner ?? true)
    }

    /// The intent this send restores into the log.
    var intent: HomeIntent {
        HomeIntent(key: key, op: .sendMessage(conversation: conversation, parts: parts, threadRoot: threadRoot, parent: parent), issuedAt: issuedAt)
    }
}
