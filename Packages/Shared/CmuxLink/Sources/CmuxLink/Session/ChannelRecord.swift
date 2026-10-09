import Foundation

/// Everything a session knows about one channel. Owned by `LinkSession`.
struct ChannelRecord: Sendable {
    enum Phase: Sendable {
        /// Not yet declared on the current transport: reliable sends are
        /// retained, others dropped.
        case awaiting
        case open
    }

    let id: UInt32
    /// Session-unique: a reused wire id never reaches an old `LinkChannel`.
    let incarnation: UInt64
    let descriptor: ChannelDescriptor
    let openedLocally: Bool
    /// The priority this side's pump sends at. Starts as the declared one;
    /// the accepting side may lower or raise its own direction (a terminal
    /// opened at `input` for keystrokes sends its output at `render`).
    var sendPriority: ChannelPriority
    /// Optional directional budget selected by the owner after opening. A
    /// terminal declares its input budget on the wire, then the host may
    /// select a separate render budget for its output direction.
    var sendBudgetOverride: Int?
    var phase: Phase = .awaiting
    /// The peer has acknowledged this channel at least once.
    var everOpened = false
    var localClosed = false
    var remoteClosed = false
    /// A `close` frame is queued on the current transport.
    var closeQueued = false
    /// A retained message does not fit the current path: replay and new
    /// sends wait for a path that carries it (head-of-line, keeps order).
    var stalled = false

    // Outbound.
    var nextRevision: UInt64 = 1
    var retained: [LinkMessage] = []
    var retainedBytes = 0
    var queuedBytes = 0
    var creditWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    var flushWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]

    // Inbound.
    var cursorEpoch: UInt64
    var lastReceived: UInt64
    var lastConsumed: UInt64
    var inbox: [ChannelEvent] = []
    var inboxHead = 0
    var inboxBytes = 0
    var consumerWaiter: CheckedContinuation<ChannelEvent?, Never>?
    /// The consumer took `.closed`.
    var finished = false

    init(id: UInt32, incarnation: UInt64, descriptor: ChannelDescriptor, openedLocally: Bool, cursorEpoch: UInt64, lastReceived: UInt64) {
        self.id = id
        self.incarnation = incarnation
        self.descriptor = descriptor
        self.openedLocally = openedLocally
        self.sendPriority = descriptor.priority
        self.sendBudgetOverride = nil
        self.cursorEpoch = cursorEpoch
        self.lastReceived = lastReceived
        self.lastConsumed = lastReceived
    }

    var isClosed: Bool { localClosed || remoteClosed }

    var hasPendingEvents: Bool { inboxHead < inbox.count }

    mutating func pushEvent(_ event: ChannelEvent) {
        if case let .message(message) = event { inboxBytes += message.payload.count }
        inbox.append(event)
    }

    mutating func popEvent() -> ChannelEvent? {
        guard inboxHead < inbox.count else { return nil }
        let event = inbox[inboxHead]
        inboxHead += 1
        if inboxHead > 64, inboxHead * 2 > inbox.count {
            inbox.removeFirst(inboxHead)
            inboxHead = 0
        }
        if case let .message(message) = event { inboxBytes -= message.payload.count }
        return event
    }

    /// Non-reliable inbound budget: drops the oldest undelivered message.
    mutating func dropOldestInboundMessage() -> Bool {
        guard let index = inbox[inboxHead...].firstIndex(where: {
            if case .message = $0 { return true }
            return false
        }) else { return false }
        if case let .message(message) = inbox[index] { inboxBytes -= message.payload.count }
        inbox.remove(at: index)
        return true
    }

    /// Releases retained payloads (the record is closed).
    mutating func dropRetained() {
        retained.removeAll()
        retainedBytes = 0
    }

    mutating func clearInbox() {
        inbox.removeAll()
        inboxHead = 0
        inboxBytes = 0
    }
}
