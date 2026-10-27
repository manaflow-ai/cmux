import CmuxNextCompat
import Dispatch

/// Where a ``DaemonConnection``'s events go: its `events` stream, or, once a consumer took them
/// (``DaemonConnection/consumeEvents(_:)``), that consumer, called on the thread that produced each
/// event (the transport's reader for every daemon event); and each event a subscriber's filter
/// matches into that subscriber's bounded inbox (``DaemonEventSubscription``).
///
/// Chrome's IO thread hands each IPC message to its listener's task runner with no task in between
/// (ipc/ipc_channel_proxy.cc, `ChannelProxy::Context::OnMessageReceivedNoFilter`). The stream put one
/// Swift cooperative-pool job, at user-initiated, between the user-interactive reader and the store's
/// inbox for every event, so the echo of a person's action waited behind whatever ran on the pool
/// (p02-threads-133). The other consumers are the IO thread's message filters
/// (`ChannelProxy::Context::AddFilter`): each sees every message on the reader, in order, and none
/// waits for another.
///
/// Order: the events the stream holds when a consumer takes over are older than any later one, so
/// the route keeps adding to the stream until the consumer has taken all it holds
/// (``deliverQueued(_:)``), then hands each new event to the consumer directly. Every hand-off runs
/// under the route's lock, so the consumer and each subscriber see one order whichever thread emits.
///
/// Bound: the stream holds the events its consumer has not taken yet, and the reader counts each
/// one's line bytes. Past ``highWater`` bytes the reader thread waits until the consumer has taken
/// the stream down to ``lowWater``, so the socket stops draining and the daemon's bounded outbound
/// queue (cmux-tui-core server/bounded_outbound.rs) applies its budget instead of the app buffering
/// without limit: Mojo's data pipe gives a producer the same `MOJO_RESULT_SHOULD_WAIT`
/// (mojo/core/data_pipe_producer_dispatcher.cc). An attach connection's reader waits the same way
/// (``TerminalEventQueue``). Events the actor emits (`connected`, `disconnected`) never wait.
final class DaemonEventRoute: Sendable {
    /// Takes one event. Called with the route's lock held: it must not block or call back into the
    /// connection.
    typealias Sink = @Sendable (DaemonEventEnvelope) -> Void

    private struct Subscriber {
        let id: UInt64
        let inbox: DaemonEventSubscription.Inbox
    }

    private struct State {
        var sink: Sink?
        /// Events added to the stream that no ``deliverQueued(_:)`` has passed on yet.
        var queued = 0
        var finished = false
        /// Set by the stream's first consumer (``takeStream()``).
        var streamTaken = false
        /// The subscribers in the order they came.
        var subscribers: [Subscriber] = []
        var lastSubscriberID: UInt64 = 0
        /// The line bytes of each event the stream holds that its consumer has not taken, oldest first.
        var backlog = DaemonEventBacklog()
        /// The reader waits on `readerWake`; whoever clears this signals it exactly once.
        var readerParked = false

        /// Whether the reader must wait now (not finished, above `highWater`); marks it parked if so.
        mutating func parkReader(above highWater: Int) -> Bool {
            readerParked = !finished && backlog.bytes > highWater
            return readerParked
        }

        /// Clears the parked mark; true when the caller must signal the reader.
        mutating func releaseReader() -> Bool {
            defer { readerParked = false }
            return readerParked
        }
    }

    /// The stream's bytes past which the reader waits for its consumer.
    let highWater: Int
    /// The reader resumes once the stream holds at most this many bytes.
    let lowWater: Int
    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation
    // concurrency-allow: the designed backpressure that makes the daemon's bounded outbound queue act: only the
    // control connection's dedicated reader thread (LineTransport) waits on it, never the main thread or a pool thread.
    private let readerWake = DispatchSemaphore(value: 0)
    /// Called on the reader thread each time it starts to wait past ``highWater``, before it waits.
    /// Tests use it to see the backpressure without timing; it must not block.
    private let onReaderParked: (@Sendable () -> Void)?

    init(_ continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation,
         highWater: Int = 8 << 20, lowWater: Int = 2 << 20, onReaderParked: (@Sendable () -> Void)? = nil) {
        self.continuation = continuation
        self.highWater = max(highWater, 1)
        self.lowWater = min(max(lowWater, 0), self.highWater)
        self.onReaderParked = onReaderParked
    }

    /// Passes `envelope` on: to each subscriber it matches, and to the consumer when it took the
    /// events and the stream holds none it has not taken, else to the stream. Dropped once the route
    /// finished, as a finished stream drops it.
    ///
    /// - Parameters:
    ///   - bytes: The event's line bytes, counted while the stream holds it.
    ///   - parksReader: True only on the reader thread: past ``highWater`` it waits here for the consumer.
    func emit(_ envelope: DaemonEventEnvelope, bytes: Int = 0, parksReader: Bool = false) {
        let parked = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            for subscriber in state.subscribers { subscriber.inbox.offer(envelope) }
            if let sink = state.sink, state.queued == 0 {
                sink(envelope)
                return false
            }
            state.queued += 1
            state.backlog.append(bytes)
            continuation.yield(envelope)
            return parksReader && state.parkReader(above: highWater)
        }
        guard parked else { return }
        onReaderParked?()
        var waiting = parked
        while waiting {
            // The designed backpressure (see the type): a checked wait, only on the control connection's
            // dedicated reader thread (LineTransport), never the main thread or a pool thread.
            readerWake.blockingWait()
            waiting = state.withLock { $0.parkReader(above: highWater) }
        }
    }

    /// The stream's consumer took its oldest event (``DaemonEventStream``'s iterator): its bytes leave
    /// the backlog, and a waiting reader resumes once at most ``lowWater`` are left.
    func took() {
        let release = state.withLock { state -> Bool in
            state.backlog.removeFirst()
            guard state.backlog.bytes <= lowWater else { return false }
            return state.releaseReader()
        }
        if release { readerWake.signal() }
    }

    /// Marks the stream taken by its one consumer (the store, or the connection's only reader). A
    /// second consumer would split the events with the first, so it traps in Debug.
    func takeStream() {
        let first = state.withLock { state -> Bool in
            let first = !state.streamTaken
            state.streamTaken = true
            return first
        }
        assert(first, "DaemonConnection.events has one consumer; take another with subscribe(filter:limit:)")
    }

    /// Makes `sink` the consumer of every later event (after the ones the stream holds).
    func attach(_ sink: @escaping Sink) {
        state.withLock { $0.sink = sink }
    }

    /// Takes the stream and drops every event it would get, and ends it; subscribers still get theirs.
    func discardStream() {
        takeStream()
        let (replaced, release) = state.withLock { state -> (Sink?, Bool) in
            let replaced = state.sink
            state.sink = { _ in }
            state.queued = 0
            state.backlog = DaemonEventBacklog()
            continuation.finish()
            return (replaced, state.releaseReader())
        }
        if release { readerWake.signal() }
        withExtendedLifetime(replaced) {}
    }

    /// Hands an event the consumer took from the stream to its sink, in order with direct ones.
    func deliverQueued(_ envelope: DaemonEventEnvelope) {
        state.withLock { state in
            state.queued = max(state.queued - 1, 0)
            state.sink?(envelope)
        }
    }

    /// Drops the consumer (its stream ended). The sink is released after the unlock: the last
    /// reference to a subscription it holds ends that subscription, which takes the lock.
    func detach() {
        let sink = state.withLock { state -> Sink? in
            let sink = state.sink
            state.sink = nil
            return sink
        }
        withExtendedLifetime(sink) {}
    }

    /// A subscriber that gets every later event `filter` matches, holding at most `limit` at once.
    /// On a finished route the subscription has already ended.
    func subscribe(filter: DaemonEventFilter, limit: Int) -> DaemonEventSubscription {
        let inbox = DaemonEventSubscription.Inbox(filter: filter, limit: limit)
        let id = state.withLock { state -> UInt64? in
            guard !state.finished else { return nil }
            state.lastSubscriberID += 1
            state.subscribers.append(Subscriber(id: state.lastSubscriberID, inbox: inbox))
            return state.lastSubscriberID
        }
        guard let id else {
            inbox.finish()
            return DaemonEventSubscription(inbox: inbox) {}
        }
        return DaemonEventSubscription(inbox: inbox) { [weak self] in self?.unsubscribe(id) }
    }

    private func unsubscribe(_ id: UInt64) {
        state.withLock { $0.subscribers.removeAll { $0.id == id } }
    }

    /// Ends the stream and every subscription: events emitted later are dropped; the ones they hold
    /// still reach their consumers. A waiting reader resumes.
    func finish(throwing error: (any Error)? = nil) {
        let (inboxes, release) = state.withLock { state -> ([DaemonEventSubscription.Inbox], Bool) in
            state.finished = true
            continuation.finish(throwing: error)
            let inboxes = state.subscribers.map(\.inbox)
            state.subscribers.removeAll()
            return (inboxes, state.releaseReader())
        }
        if release { readerWake.signal() }
        for inbox in inboxes { inbox.finish() }
    }

    /// Subscribers the route delivers to now (tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Events in the stream that its consumer has not passed on (tests).
    var streamBacklog: Int { state.withLock { $0.queued } }

    /// Line bytes of the events the stream holds that its consumer has not taken (tests).
    var streamBacklogBytes: Int { state.withLock { $0.backlog.bytes } }

    /// True while the reader waits for the consumer (tests).
    var isReaderParked: Bool { state.withLock { $0.readerParked } }
}

/// The line bytes of the events a ``DaemonEventRoute``'s stream holds, oldest first.
struct DaemonEventBacklog {
    private var sizes: [Int] = []
    private var head = 0
    /// The sum of the sizes held.
    private(set) var bytes = 0

    mutating func append(_ size: Int) {
        sizes.append(size)
        bytes += size
    }

    /// Drops the oldest size; nothing when none is held.
    mutating func removeFirst() {
        guard head < sizes.count else { return }
        bytes -= sizes[head]
        head += 1
        if head == sizes.count {
            sizes.removeAll(keepingCapacity: sizes.count <= 1024)
            head = 0
        } else if head > 1024, head * 2 > sizes.count {
            sizes.removeFirst(head)
            head = 0
        }
    }
}
