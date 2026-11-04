import Foundation

/// The loaded part of one conversation's log: a contiguous, ascending run of
/// messages that ends at the newest message the mirror has seen.
public struct TranscriptWindow: Hashable, Sendable {
    public private(set) var messages: [Message]
    /// True once `history` returned everything before the first message.
    public var reachedStart: Bool

    public init(messages: [Message] = [], reachedStart: Bool = false) {
        self.messages = messages.sorted { $0.seq < $1.seq }
        self.reachedStart = reachedStart || (self.messages.first?.seq ?? 1) <= 1
    }

    /// An empty window that buffers events until the first page arrives.
    static func loading() -> TranscriptWindow {
        var window = TranscriptWindow()
        window.reachedStart = false
        return window
    }

    public var firstSeq: Seq? { messages.first?.seq }
    public var lastSeq: Seq? { messages.last?.seq }

    /// Applies a committed or updated message. Returns false when the message
    /// is newer than lastSeq + 1 (a gap: refetch the tail).
    mutating func apply(_ message: Message) -> Bool {
        if let index = messages.lastIndex(where: { $0.seq == message.seq }) {
            messages[index] = message
            return true
        }
        guard let last = lastSeq else {
            messages = [message]
            return true
        }
        if message.seq == last + 1 {
            messages.append(message)
            return true
        }
        if message.seq < (firstSeq ?? 0) { return true } // older than the window: not loaded, ignore
        return message.seq <= last
    }

    /// Prepends an older page. The page must end right before the window.
    /// Returns false (and changes nothing) when it does not join.
    @discardableResult
    mutating func prepend(_ older: [Message], reachedStart: Bool) -> Bool {
        let first = firstSeq ?? .max
        let fresh = older.filter { $0.seq < first }.sorted { $0.seq < $1.seq }
        if let last = fresh.last?.seq, first != .max, last != first - 1 { return false }
        messages.insert(contentsOf: fresh, at: 0)
        self.reachedStart = reachedStart || (messages.first?.seq ?? 1) <= 1
        return true
    }

    /// Replaces the window with a fetched tail. Buffered messages newer than
    /// the page and loaded history right before it are kept. Returns false
    /// when buffered newer messages do not join the page (a hole: refetch).
    mutating func adopt(page: [Message]) -> Bool {
        let sorted = page.sorted { $0.seq < $1.seq }
        guard let pageFirst = sorted.first?.seq, let pageLast = sorted.last?.seq else {
            if messages.isEmpty { reachedStart = true }
            return true
        }
        let newer = messages.filter { $0.seq > pageLast }
        let joins = newer.first.map { $0.seq == pageLast + 1 } ?? true
        let older = messages.filter { $0.seq < pageFirst }
        let keepOlder = older.last.map { $0.seq == pageFirst - 1 } ?? false
        let start = keepOlder ? reachedStart : pageFirst <= 1
        messages = (keepOlder ? older : []) + sorted + (joins ? newer : [])
        reachedStart = start
        return joins
    }

    /// Drops loaded history above the newest `keep` messages, for a reader
    /// resting at the newest message: those rows are far off screen and load
    /// again as older pages if the reader scrolls back up. The cut moves up
    /// to keep every message a kept message answers or threads under, and
    /// every id in `preserving`. Returns whether anything was dropped.
    @discardableResult
    mutating func trimOlder(keepingNewest keep: Int, preserving: Set<MessageID> = [], atMost limit: Int = .max) -> Bool {
        guard keep > 0, messages.count > keep else { return false }
        var cut = messages.count - keep
        var needed = preserving
        for message in messages[cut...] {
            if let reply = message.replyTo?.message { needed.insert(reply) }
            if let root = message.threadRoot { needed.insert(root) }
        }
        if !needed.isEmpty, let first = messages[..<cut].firstIndex(where: { needed.contains($0.id) }) {
            cut = first
        }
        // What it keeps never holds the window above `limit`: one reply to an old message or a
        // long thread must not stop the bound for good (a quote whose message is dropped
        // falls back to the owner's transcript).
        cut = max(cut, messages.count - limit)
        guard cut > 0 else { return false }
        messages.removeFirst(cut)
        reachedStart = false
        return true
    }

    func message(clientID key: IdempotencyKey) -> Message? {
        messages.last { $0.clientMessageID == key }
    }
}
