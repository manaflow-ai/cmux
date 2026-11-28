import Foundation

/// What applying one event did, so the store can refetch on a gap.
public enum MirrorOutcome: Hashable, Sendable {
    case applied
    case ignoredStale
    /// The stream is behind its owner; refetch it.
    case gap(HomeStream)
}

/// The confirmed state: written only by owner events and fetched pages,
/// never by the client's own intents (those live in `IntentLog`).
public struct HomeMirror: Hashable, Sendable {
    public private(set) var me: Participant?
    public private(set) var conversations: [ConversationID: ConversationSummary] = [:]
    public private(set) var windows: [ConversationID: TranscriptWindow] = [:]
    public private(set) var revisions: [HomeStream: Revision] = [:]
    /// Streams known to be behind their owner (a gap, or a newer revision in
    /// a snapshot) until a fetch catches them up. Nothing settles against them.
    public private(set) var stale: Set<HomeStream> = []

    public init() {}

    public func revision(of stream: HomeStream) -> Revision { revisions[stream] ?? 0 }
    public func isStale(_ stream: HomeStream) -> Bool { stale.contains(stream) }

    /// Applies the account inbox. Returns the loaded conversations whose
    /// owner revision is ahead of their window; the caller refetches them.
    @discardableResult
    public mutating func apply(inbox snapshot: InboxSnapshot) -> [HomeStream] {
        me = snapshot.me
        var next: [ConversationID: ConversationSummary] = [:]
        var refetch: [HomeStream] = []
        for summary in snapshot.conversations {
            let stream = HomeStream.conversation(summary.id)
            next[summary.id] = mergedSummary(summary, fromInbox: true)
            if windows[summary.id] != nil {
                // A loaded window moves only with its own events and pages.
                if summary.rev > revision(of: stream) {
                    stale.insert(stream)
                    refetch.append(stream)
                }
            } else {
                revisions[stream] = max(revisions[stream] ?? 0, summary.rev)
            }
        }
        conversations = next
        windows = windows.filter { next[$0.key] != nil }
        revisions[.inbox] = snapshot.rev
        stale.remove(.inbox)
        return refetch
    }

    /// Seeds an empty mirror from the client's cache before the owner
    /// answers. The inbox and every seeded window are stale with no
    /// revision: nothing settles against them, the first connection fetches
    /// them, and the owner's answer replaces them.
    public mutating func seed(_ snapshot: HomeCacheSnapshot) {
        guard conversations.isEmpty, windows.isEmpty else { return }
        me = snapshot.me
        for summary in snapshot.conversations { conversations[summary.id] = summary }
        for (id, messages) in snapshot.windows where conversations[id] != nil && !messages.isEmpty {
            windows[id] = TranscriptWindow(messages: messages)
            stale.insert(.conversation(id))
        }
        stale.insert(.inbox)
    }

    /// Starts buffering a conversation's events before its first page
    /// arrives, so nothing committed during the fetch is lost.
    public mutating func beginLoading(_ conversation: ConversationID) {
        if windows[conversation] == nil { windows[conversation] = .loading() }
    }

    /// Applies a fetched tail. If the owner moved past the page while it was
    /// read, or buffered messages do not join it, the stream stays stale.
    @discardableResult
    public mutating func apply(page: ConversationPage) -> MirrorOutcome {
        let id = page.conversation.id
        let stream = HomeStream.conversation(id)
        conversations[id] = mergedSummary(page.conversation, fromInbox: false)
        var window = windows[id] ?? .loading()
        let joined = window.adopt(page: page.messages)
        windows[id] = window
        let known = revisions[stream] ?? 0
        revisions[stream] = max(known, page.conversation.rev)
        if known > page.conversation.rev || !joined {
            stale.insert(stream)
            return .gap(stream)
        }
        stale.remove(stream)
        return .applied
    }

    /// Prepends older history. False when the page no longer joins the window
    /// (it was replaced during the fetch); the caller drops the page.
    @discardableResult
    public mutating func prepend(_ older: [Message], to conversation: ConversationID, reachedStart: Bool) -> Bool {
        guard var window = windows[conversation] else { return false }
        let joined = window.prepend(older, reachedStart: reachedStart)
        windows[conversation] = window
        return joined
    }

    /// The transcript left the screen: its window goes, so nothing is
    /// fetched for it until it opens again, and that open loads its tail.
    public mutating func endTranscript(_ conversation: ConversationID) {
        windows[conversation] = nil
        stale.remove(.conversation(conversation))
    }

    /// A refetch failed: the stream stays stale until a later fetch succeeds.
    public mutating func markStale(_ stream: HomeStream) { stale.insert(stream) }

    @discardableResult
    public mutating func apply(_ event: HomeEvent) -> MirrorOutcome {
        switch event {
        case .connection, .typing, .ownerRecovered, .intentsRevoked:
            return .applied
        case .inbox(let snapshot):
            return apply(inbox: snapshot).first.map(MirrorOutcome.gap) ?? .applied
        case .conversationChanged(let summary, let stream, let rev):
            let outcome = advance(stream, to: rev)
            if outcome == .ignoredStale { return outcome }
            conversations[summary.id] = mergedSummary(summary, fromInbox: stream == .inbox)
            return outcome
        case .conversationRemoved(let id, let inboxRev):
            let outcome = advance(.inbox, to: inboxRev)
            if outcome == .ignoredStale { return outcome }
            conversations[id] = nil
            windows[id] = nil
            return outcome
        case .message(let message, let rev):
            return apply(message: message, rev: rev)
        case .conversationPage(let page):
            let id = page.conversation.id
            if windows[id] != nil { return apply(page: page) }
            let stream = HomeStream.conversation(id)
            if let known = revisions[stream], known > page.conversation.rev { return .ignoredStale }
            conversations[id] = mergedSummary(page.conversation, fromInbox: false)
            revisions[stream] = page.conversation.rev
            stale.remove(stream)
            return .applied
        }
    }

    private mutating func apply(message: Message, rev: Revision) -> MirrorOutcome {
        let stream = HomeStream.conversation(message.conversation)
        var outcome = advance(stream, to: rev)
        if outcome == .ignoredStale { return outcome }
        if var window = windows[message.conversation] {
            if !window.apply(message) {
                outcome = .gap(stream)
                stale.insert(stream)
            }
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
        if rev == current + 1 { return .applied }
        stale.insert(stream)
        return .gap(stream)
    }

    /// Pin and mute belong to the account inbox owner: only inbox snapshots
    /// and inbox-stream events change them. Read cursors only move forward,
    /// and a summary never moves the last message backward.
    private func mergedSummary(_ incoming: ConversationSummary, fromInbox: Bool) -> ConversationSummary {
        guard let existing = conversations[incoming.id] else { return incoming }
        var merged = incoming
        if !fromInbox {
            merged.pinRank = existing.pinRank
            merged.muted = existing.muted
        }
        merged.readCursors = existing.readCursors.merging(incoming.readCursors) { max($0, $1) }
        merged.readCursorTimes = existing.readCursorTimes.merging(incoming.readCursorTimes) { max($0, $1) }
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
