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
            reachedStart = message.seq <= 1
            return true
        }
        if message.seq == last + 1 {
            messages.append(message)
            return true
        }
        if message.seq < (firstSeq ?? 0) { return true } // older than the window: not loaded, ignore
        return message.seq <= last
    }

    /// Prepends an older page. Pages must touch or overlap the window.
    mutating func prepend(_ older: [Message], reachedStart: Bool) {
        let first = firstSeq ?? .max
        let fresh = older.filter { $0.seq < first }.sorted { $0.seq < $1.seq }
        messages.insert(contentsOf: fresh, at: 0)
        self.reachedStart = reachedStart || (messages.first?.seq ?? 1) <= 1
    }

    func message(clientID key: IdempotencyKey) -> Message? {
        messages.last { $0.clientMessageID == key }
    }
}

/// What applying one event did, so the store can refetch on a gap.
public enum MirrorOutcome: Hashable, Sendable {
    case applied
    case ignoredStale
    /// The stream skipped a revision; refetch it.
    case gap(HomeStream)
}

/// The confirmed state: written only by owner events and fetched pages,
/// never by the client's own intents (those live in `IntentLog`).
public struct HomeMirror: Hashable, Sendable {
    public private(set) var me: Participant?
    public private(set) var conversations: [ConversationID: ConversationSummary] = [:]
    public private(set) var windows: [ConversationID: TranscriptWindow] = [:]
    public private(set) var revisions: [HomeStream: Revision] = [:]

    public init() {}

    public func revision(of stream: HomeStream) -> Revision { revisions[stream] ?? 0 }

    public mutating func apply(inbox snapshot: InboxSnapshot) {
        me = snapshot.me
        var next: [ConversationID: ConversationSummary] = [:]
        for summary in snapshot.conversations {
            next[summary.id] = summary
            revisions[.conversation(summary.id)] = max(revisions[.conversation(summary.id)] ?? 0, summary.rev)
        }
        conversations = next
        windows = windows.filter { next[$0.key] != nil }
        revisions[.inbox] = snapshot.rev
    }

    public mutating func apply(page: ConversationPage) {
        let id = page.conversation.id
        conversations[id] = mergedSummary(page.conversation)
        windows[id] = TranscriptWindow(messages: page.messages)
        revisions[.conversation(id)] = max(revisions[.conversation(id)] ?? 0, page.conversation.rev)
    }

    public mutating func prepend(_ older: [Message], to conversation: ConversationID, reachedStart: Bool) {
        windows[conversation, default: TranscriptWindow()].prepend(older, reachedStart: reachedStart)
    }

    @discardableResult
    public mutating func apply(_ event: HomeEvent) -> MirrorOutcome {
        switch event {
        case .connection, .typing:
            return .applied
        case .inbox(let snapshot):
            apply(inbox: snapshot)
            return .applied
        case .conversationChanged(let summary, let stream, let rev):
            let outcome = advance(stream, to: rev)
            if outcome == .ignoredStale { return outcome }
            conversations[summary.id] = mergedSummary(summary)
            return outcome
        case .conversationRemoved(let id, let inboxRev):
            let outcome = advance(.inbox, to: inboxRev)
            if outcome == .ignoredStale { return outcome }
            conversations[id] = nil
            windows[id] = nil
            return outcome
        case .message(let message, let rev):
            let stream = HomeStream.conversation(message.conversation)
            var outcome = advance(stream, to: rev)
            if outcome == .ignoredStale { return outcome }
            if var window = windows[message.conversation] {
                if !window.apply(message) { outcome = .gap(stream) }
                windows[message.conversation] = window
            }
            if var summary = conversations[message.conversation] {
                if message.seq >= summary.lastSeq {
                    summary.lastSeq = message.seq
                    summary.lastMessage = message
                    summary.updatedAt = max(summary.updatedAt, message.createdAt)
                }
                summary.rev = max(summary.rev, rev)
                conversations[message.conversation] = summary
            }
            return outcome
        }
    }

    /// Moves a stream's revision forward. A repeat is stale; a jump is a gap
    /// (the event still applies, and the caller refetches).
    private mutating func advance(_ stream: HomeStream, to rev: Revision) -> MirrorOutcome {
        guard let current = revisions[stream] else {
            // First event of a stream the mirror never fetched: nothing to compare.
            revisions[stream] = rev
            return .applied
        }
        if rev <= current { return .ignoredStale }
        revisions[stream] = rev
        return rev == current + 1 ? .applied : .gap(stream)
    }

    /// Account-inbox fields (pin, mute) and read cursors are kept when an
    /// event from the conversation stream does not carry them.
    private func mergedSummary(_ incoming: ConversationSummary) -> ConversationSummary {
        guard let existing = conversations[incoming.id] else { return incoming }
        var merged = incoming
        merged.readCursors = existing.readCursors.merging(incoming.readCursors) { max($0, $1) }
        if merged.lastSeq < existing.lastSeq {
            merged.lastSeq = existing.lastSeq
            merged.lastMessage = existing.lastMessage
        }
        return merged
    }

    func message(clientID key: IdempotencyKey, in conversation: ConversationID) -> Message? {
        if let found = windows[conversation]?.message(clientID: key) { return found }
        if let last = conversations[conversation]?.lastMessage, last.clientMessageID == key { return last }
        return nil
    }
}
