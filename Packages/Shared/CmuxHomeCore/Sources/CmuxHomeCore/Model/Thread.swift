public import Foundation

/// The owner's stats of one thread root (cx-59n8.6): counted by the owner at
/// read time over every reply, so a root shows the right count also when its
/// replies are not in the loaded window. A retracted reply still counts.
public struct ThreadSummary: Hashable, Sendable {
    public var root: MessageID
    public var replyCount: Int
    /// The newest reply's seq; nil when there is no reply.
    public var lastReplySeq: Seq?
    /// The newest reply's time; nil when there is no reply.
    public var lastReplyAt: Date?
    /// The first three distinct reply authors, oldest reply first.
    public var authors: [ParticipantID]

    public init(root: MessageID, replyCount: Int, lastReplySeq: Seq? = nil, lastReplyAt: Date? = nil, authors: [ParticipantID] = []) {
        self.root = root
        self.replyCount = replyCount
        self.lastReplySeq = lastReplySeq
        self.lastReplyAt = lastReplyAt
        self.authors = authors
    }

    /// Stats counted over `replies` only (a source without the owner read).
    public init(root: MessageID, replies: [Message]) {
        var authors: [ParticipantID] = []
        for reply in replies where authors.count < 3 && !authors.contains(reply.author) { authors.append(reply.author) }
        let last = replies.max { $0.seq < $1.seq }
        self.init(root: root, replyCount: replies.count, lastReplySeq: last?.seq, lastReplyAt: last?.createdAt, authors: authors)
    }
}

/// One page of a thread: its root, replies after a seq (ascending), and the
/// owner's stats of the whole thread.
public struct ThreadPage: Hashable, Sendable {
    public var root: Message
    public var replies: [Message]
    /// More replies follow the last one in `replies`.
    public var hasMore: Bool
    public var summary: ThreadSummary

    public init(root: Message, replies: [Message], hasMore: Bool, summary: ThreadSummary) {
        self.root = root
        self.replies = replies
        self.hasMore = hasMore
        self.summary = summary
    }
}

/// One older page of a conversation with the owner's stats of the thread
/// roots in it (empty from an owner without thread stats).
public struct HistoryPage: Hashable, Sendable {
    public var messages: [Message]
    public var threads: [ThreadSummary]

    public init(messages: [Message], threads: [ThreadSummary] = []) {
        self.messages = messages
        self.threads = threads
    }
}

extension HomeSource {
    /// Default for owners without thread stats: the plain history page.
    public func historyPage(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> HistoryPage {
        HistoryPage(messages: try await history(of: conversation, before: beforeSeq, limit: limit))
    }

    /// Default for owners without the thread read: ``scanThread(of:root:after:limit:)``.
    public func thread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage {
        try await scanThread(of: conversation, root: root, after: afterSeq, limit: limit)
    }

    /// Pages the history from the newest message back to the root (at most
    /// ``fallbackThreadScan`` messages) and keeps the root's replies. Counts
    /// only what it scanned. A source whose owner lacks the thread read calls it.
    public func scanThread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage {
        var before = Seq.max
        var scanned = 0
        var rootMessage: Message?
        var replies: [Message] = []
        scan: while scanned < Self.fallbackThreadScan {
            let page = try await history(of: conversation, before: before, limit: 200)
            guard let oldest = page.first else { break }
            scanned += page.count
            for message in page.reversed() {
                if message.id == root { rootMessage = message; break scan }
                if message.threadRoot == root { replies.append(message) }
            }
            before = oldest.seq
        }
        guard let rootMessage, rootMessage.threadRoot == nil else { throw HomeRejection.invalid("unknown_message") }
        replies.reverse()
        let after = replies.filter { $0.seq > afterSeq }
        let bounded = Array(after.prefix(max(limit, 1)))
        return ThreadPage(root: rootMessage, replies: bounded, hasMore: after.count > bounded.count,
                          summary: ThreadSummary(root: root, replies: replies))
    }

    /// Most messages the fallback thread read scans.
    public static var fallbackThreadScan: Int { 2_000 }
}
