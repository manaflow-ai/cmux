public import Foundation

/// Where a reader was in a conversation: the newest visible message and its
/// offset from the bottom of the viewport, in points. A message newer than
/// `message` scrolls to the bottom instead.
public struct HomeScrollAnchor: Hashable, Sendable, Codable {
    public var message: MessageID
    public var offset: Double

    public init(message: MessageID, offset: Double) {
        self.message = message
        self.offset = offset
    }
}

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

/// A picture or file left in a compose field: its ref and its files in the
/// client blob cache, so the chip comes back after a relaunch with the text.
public struct HomeCachedDraftAttachment: Hashable, Sendable, Codable {
    public var ref: AttachmentRef
    public var fileURL: URL
    public var posterURL: URL?
    public var previewURL: URL?

    public init(_ attachment: LocalAttachment) {
        ref = attachment.ref
        fileURL = attachment.fileURL
        posterURL = attachment.posterURL
        previewURL = attachment.previewURL
    }

    /// Its file, poster and preview, whichever it has.
    var urls: [URL] { [fileURL, posterURL, previewURL].compactMap { $0 } }

    /// The prepared attachment again; nil once the blob cache no longer holds
    /// its bytes, its poster or its preview (a send needs all three).
    var local: LocalAttachment? {
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return LocalAttachment(ref: ref, fileURL: fileURL, posterURL: posterURL, previewURL: previewURL)
    }
}

/// What the cache holds (plans/cmux-next/home-state-ownership.md section 4):
/// the owner's last inbox and the tail of each opened conversation, as the
/// mirror had them, plus the client's own state (unsent sends, drafts, scroll
/// anchors). A copy, never a writer: the owner's answers overwrite it.
public struct HomeCacheSnapshot: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version = HomeCacheSnapshot.currentVersion
    public var me: Participant?
    public var conversations: [ConversationSummary] = []
    /// The newest messages of each conversation the reader opened (at most
    /// `HomeCache.windowLimit`), ascending.
    public var windows: [ConversationID: [Message]] = [:]
    public var sends: [HomeCachedSend] = []
    public var drafts: [ConversationID: String] = [:]
    public var scroll: [ConversationID: HomeScrollAnchor] = [:]
    /// The attachments in each compose field, in order. Optional: a cache
    /// written before drafts kept them still decodes.
    public var draftAttachments: [ConversationID: [HomeCachedDraftAttachment]]?

    public init() {}
}

/// The client's durable Home cache: one JSON file per owner and account
/// (`~/Library/Caches/cmux-home/<owner key>/home.json` on the Mac). Written
/// whole, atomically; a file that does not decode is ignored, since the owner
/// can rebuild everything in it but drafts and unsent sends.
public struct HomeCache: Sendable, Hashable {
    /// Messages kept per opened conversation.
    public static let windowLimit = 200

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Caches/cmux-home/<owner>/home.json`; `owner` is made a single path component.
    public static func standard(owner: String) -> HomeCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let component = String(owner.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return HomeCache(url: caches.appendingPathComponent("cmux-home/\(component)/home.json"))
    }

    public func load() -> HomeCacheSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HomeCacheSnapshot.self, from: data),
              snapshot.version == HomeCacheSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func save(_ snapshot: HomeCacheSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
