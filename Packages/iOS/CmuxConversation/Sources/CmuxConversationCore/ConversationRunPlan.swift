import Foundation

/// Messages grouping rules, independent of rendering: which messages start a
/// timestamp section, which bubbles form a run (tail on the last), and which
/// single outgoing message carries the delivery status.
public struct ConversationRunPlan: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case none
        case delivered
        case read(Date?)
        case notDelivered
        /// "Delivered Quietly": the recipient's Focus silenced notifications.
        case deliveredQuietly
    }

    public struct Entry: Sendable, Equatable {
        public var showsTimestamp: Bool
        public var isFirstInRun: Bool
        public var isLastInRun: Bool
        public var status: Status
        /// Where an inline reply sits in its thread's block; nil for a
        /// message that is not drawn as a thread reply (not a reply, or a
        /// reply right under the message it answers).
        public var replyThread: ReplyThread? = nil
    }

    /// An inline reply's place in a thread block, as Messages lays it out
    /// (iOS 27.0, ChatKit's `_shouldAppendReplyContextForItem:previousItem:`
    /// on a simulator Messages with its thread links restored):
    /// - a reply right under the message it answers gets no quote and no
    ///   line (it reads as the next bubble);
    /// - otherwise the first reply of a block draws the quote of the thread's
    ///   root, and each reply of the same thread right under it joins that
    ///   block: no quote of its own, the line running on from the quote down
    ///   to the block's last reply.
    public struct ReplyThread: Sendable, Hashable {
        /// How the line reaches a reply that continues a block.
        public enum Arrival: Sendable, Hashable {
            /// It runs on from the row above (a reply on the trailing side,
            /// which the line passes beside).
            case line
            /// It starts again under the row above: that reply is on the
            /// leading side, where the line stops above it.
            case belowLeading
        }

        /// The block's first reply: the quote of the thread's root above it.
        public var showsQuote: Bool
        /// Set when the reply continues a block (no quote of its own).
        public var arrival: Arrival?
        /// The next row continues this block, so the line runs on below.
        public var continuesBelow: Bool

        public init(showsQuote: Bool, arrival: Arrival?, continuesBelow: Bool) {
            self.showsQuote = showsQuote
            self.arrival = arrival
            self.continuesBelow = continuesBelow
        }
    }

    /// A message's link to the thread of the message above it.
    enum ThreadLink: Equatable {
        /// Not drawn as a thread reply.
        case none
        /// A reply right under the message it answers (or a reply joining
        /// such a reply): drawn as a plain bubble.
        case adjacent
        /// The first reply of a block: it shows the quote.
        case quoted
        /// A reply that joins the block above it.
        case continued
    }

    /// The walk's state at one message: its link, and the ids its block
    /// answers to (the block's replies and the messages they answer), so a
    /// reply to any of them joins the block as in Messages' flat threads.
    struct ThreadState {
        var link: ThreadLink = .none
        var ids: Set<String> = []
    }

    public var entries: [Entry]

    /// A gap this long starts a new timestamp section.
    public static let timestampGap: TimeInterval = 60 * 60
    /// Same-sender messages further apart than this start a new run.
    public static let runGap: TimeInterval = 5 * 60

    /// The message that carries the delivery status, if any.
    public private(set) var statusIndex: Int?

    /// `limit` plans only the first `limit` messages (the entries the whole
    /// plan gives them): an older page needs entries for itself and the
    /// message under it, not for the whole transcript.
    ///
    /// `threadBlocks` lays inline replies out in thread blocks (`ReplyThread`);
    /// without it every reply is a run of its own and carries no block.
    public init(messages: [ConversationMessage], meID: String?, typingParticipantIDs: [String] = [], limit: Int? = nil, threadBlocks: Bool = false) {
        let firstScheduled = messages.firstIndex(where: \.isScheduled) ?? messages.count
        self.init(messages: messages, meID: meID, typingParticipantIDs: typingParticipantIDs, range: 0..<min(limit ?? messages.count, messages.count), firstScheduled: firstScheduled, threadBlocks: threadBlocks)
    }

    /// Plans only `range` (`entries[k]` is message `range.lowerBound + k`),
    /// reading the transcript from its end: a live change rebuilds the rows
    /// at the bottom of a long transcript without walking all of it. Send
    /// Later messages must trail the others, as the store keeps them.
    public init(messages: [ConversationMessage], meID: String?, typingParticipantIDs: [String] = [], range: Range<Int>, threadBlocks: Bool = false) {
        var firstScheduled = messages.count
        while firstScheduled > 0, messages[firstScheduled - 1].isScheduled { firstScheduled -= 1 }
        self.init(messages: messages, meID: meID, typingParticipantIDs: typingParticipantIDs, range: range.clamped(to: 0..<messages.count), firstScheduled: firstScheduled, threadBlocks: threadBlocks)
    }

    private init(messages: [ConversationMessage], meID: String?, typingParticipantIDs: [String], range: Range<Int>, firstScheduled: Int, threadBlocks: Bool) {
        // Status sits under the newest delivered/read message of mine; it moves
        // only once a newer one is delivered, never while that one is in flight.
        var lastAckedOutgoing = messages.lastIndex { message in
            guard message.senderID == meID, !message.isUnsent, !message.isSystemEvent else { return false }
            switch message.delivery {
            case .delivered, .read: return true
            default: return false
            }
        }
        // Once someone replies below it, the status has done its job (a
        // status row such as someone leaving is not a reply).
        if let index = lastAckedOutgoing, messages[(index + 1)...].contains(where: { $0.senderID != meID && !$0.isSystemEvent }) {
            lastAckedOutgoing = nil
        }
        statusIndex = lastAckedOutgoing
        var entries: [Entry] = []
        entries.reserveCapacity(range.count)
        // Send Later messages trail the transcript, each its own tailed bubble
        // under a "Send Later" header the renderer draws; the history above
        // groups as if they were not there.
        // Neighbors are read in place: copying whole messages into optionals
        // dominated this pass, which runs over every loaded message per update.
        // Each message's thread state, carried down from the one above.
        var nextThread = range.isEmpty || !threadBlocks ? ThreadState() : Self.threadState(messages: messages, at: range.lowerBound, firstScheduled: firstScheduled)
        for index in range {
            let message = messages[index]
            let thread = nextThread
            let link = thread.link
            nextThread = threadBlocks && index + 1 < firstScheduled ? Self.threadState(of: messages[index + 1], previous: message, previousState: thread) : ThreadState()
            if index >= firstScheduled {
                let failed = message.delivery?.isFailed == true
                entries.append(Entry(showsTimestamp: false, isFirstInRun: true, isLastInRun: true, status: failed ? .notDelivered : .none))
                continue
            }
            let hasPrevious = index > 0
            let hasNext = index + 1 < firstScheduled
            let showsTimestamp = hasPrevious ? message.sentAt.timeIntervalSince(messages[index - 1].sentAt) >= Self.timestampGap : true
            let firstInRun = showsTimestamp || !(hasPrevious && Self.sameRun(messages[index - 1], message, threadBlocks: threadBlocks, joined: link))
            let lastInRun: Bool
            if !hasNext {
                lastInRun = !typingParticipantIDs.contains(message.senderID)
            } else if messages[index + 1].sentAt.timeIntervalSince(message.sentAt) >= Self.timestampGap {
                lastInRun = true
            } else {
                lastInRun = !Self.sameRun(message, messages[index + 1], threadBlocks: threadBlocks, joined: nextThread.link)
            }
            let status: Status
            if message.delivery?.isFailed == true {
                status = .notDelivered
            } else if message.senderID == meID, index == lastAckedOutgoing {
                switch message.delivery {
                case .delivered: status = message.deliveredQuietly ? .deliveredQuietly : .delivered
                case let .read(date): status = .read(date)
                default: status = .none
                }
            } else {
                status = .none
            }
            var replyThread: ReplyThread?
            if link == .quoted || link == .continued {
                let nextLink = nextThread.link
                let arrival: ReplyThread.Arrival? = link == .quoted ? nil : (messages[index - 1].senderID == meID ? .line : .belowLeading)
                replyThread = ReplyThread(showsQuote: link == .quoted, arrival: arrival, continuesBelow: nextLink == .continued)
            }
            // A status row under a bubble ends its visual run (Messages keeps
            // the tail there until the status moves to a newer message).
            entries.append(Entry(showsTimestamp: showsTimestamp, isFirstInRun: firstInRun, isLastInRun: lastInRun || status != .none, status: status, replyThread: replyThread))
        }
        self.entries = entries
    }

    /// `joined` is the thread link of `b` under `a` (thread blocks only).
    static func sameRun(_ a: ConversationMessage, _ b: ConversationMessage, threadBlocks: Bool, joined: ThreadLink = .none) -> Bool {
        // An unsent message or a group status row renders as a centered
        // notice, which ends the run above it (that bubble regains its tail)
        // and starts a new one below (sender name and all).
        // A tapback makes its message a run of its own in Messages (iOS 26.5
        // and 27.0): the bubble above regains its tail, the reacted bubble
        // keeps one, and the next starts a new run 10 pt down.
        // An inline reply is a run of its own too: Messages separates the
        // quote, line and reply from both neighbors (the next bubble from the
        // same sender starts a new run under it), and a reply right under the
        // message it answers from that message. With thread blocks, replies
        // of one thread in a row share a block and run together (the first
        // loses its tail), as do replies under a reply right under its message.
        !a.isUnsent && !b.isUnsent && !a.isSystemEvent && !b.isSystemEvent && a.senderID == b.senderID && b.sentAt.timeIntervalSince(a.sentAt) < runGap
            && (threadBlocks && a.replyToID != nil && (joined == .continued || joined == .adjacent) || a.replyToID == nil && b.replyToID == nil)
            && a.reactions.isEmpty && b.reactions.isEmpty
    }

    /// The message the thread of a reply to `id` started from. Messages keeps
    /// one flat thread per root, so a reply to a reply quotes the root. Nil
    /// when the root is not loaded (the chain ends at a reply).
    public static func threadRoot(of id: String, message: (String) -> ConversationMessage?) -> ConversationMessage? {
        guard var root = message(id) else { return nil }
        // A chain of replies is short; the bound stops a cycle in bad data.
        for _ in 0..<64 {
            guard let up = root.replyToID else { return root }
            guard let parent = message(up) else { return nil }
            root = parent
        }
        return nil
    }

    /// The thread state of `message` under `previous`, given the state of
    /// `previous` itself. A timestamp section between them starts a new block.
    static func threadState(of message: ConversationMessage, previous: ConversationMessage, previousState: ThreadState) -> ThreadState {
        guard let parent = message.replyToID, !message.isUnsent, !message.isSystemEvent else { return ThreadState() }
        let starts = ThreadState(link: .quoted, ids: [message.id, parent])
        guard !previous.isUnsent, !previous.isSystemEvent, message.sentAt.timeIntervalSince(previous.sentAt) < timestampGap else { return starts }
        if previous.id == parent, previous.replyToID == nil { return ThreadState(link: .adjacent, ids: [parent, message.id]) }
        // Under a reply of the same thread (one answering any message of the
        // block, or a message the block answers), it joins that reply's
        // block, or reads as a bubble under one.
        guard previousState.link != .none, previousState.ids.contains(parent) else { return starts }
        var ids = previousState.ids
        ids.insert(message.id)
        return ThreadState(link: previousState.link == .adjacent ? .adjacent : .continued, ids: ids)
    }

    /// The thread state of the message at `index`, read back only as far as
    /// the run of replies above it reaches.
    static func threadState(messages: [ConversationMessage], at index: Int, firstScheduled: Int) -> ThreadState {
        guard index < firstScheduled else { return ThreadState() }
        var start = index
        // The reply chain above a message rarely runs past a few rows; the
        // bound keeps a pathological transcript from walking all of it.
        while start > 0, index - start < 64, mayJoin(messages[start], messages[start - 1]) { start -= 1 }
        let first = messages[start]
        var state = first.replyToID.map { first.isUnsent || first.isSystemEvent ? ThreadState() : ThreadState(link: .quoted, ids: [first.id, $0]) } ?? ThreadState()
        if start < index {
            for i in (start + 1)...index { state = threadState(of: messages[i], previous: messages[i - 1], previousState: state) }
        }
        return state
    }

    /// Whether `message` can join the thread of `previous`: it is a reply, and
    /// `previous` is a reply too or the message it answers.
    private static func mayJoin(_ message: ConversationMessage, _ previous: ConversationMessage) -> Bool {
        guard let parent = message.replyToID else { return false }
        return previous.replyToID != nil || previous.id == parent
    }
}
