import CmuxNextCompat

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
    }

    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// Passes `envelope` on: to each subscriber it matches, and to the consumer when it took the
    /// events and the stream holds none it has not taken, else to the stream. Dropped once the route
    /// finished, as a finished stream drops it.
    func emit(_ envelope: DaemonEventEnvelope) {
        state.withLock { state in
            guard !state.finished else { return }
            for subscriber in state.subscribers { subscriber.inbox.offer(envelope) }
            if let sink = state.sink, state.queued == 0 { return sink(envelope) }
            state.queued += 1
            continuation.yield(envelope)
        }
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
        let replaced = state.withLock { state -> Sink? in
            let replaced = state.sink
            state.sink = { _ in }
            state.queued = 0
            continuation.finish()
            return replaced
        }
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
    /// still reach their consumers.
    func finish(throwing error: (any Error)? = nil) {
        let inboxes = state.withLock { state -> [DaemonEventSubscription.Inbox] in
            state.finished = true
            continuation.finish(throwing: error)
            let inboxes = state.subscribers.map(\.inbox)
            state.subscribers.removeAll()
            return inboxes
        }
        for inbox in inboxes { inbox.finish() }
    }

    /// Subscribers the route delivers to now (tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Events in the stream that its consumer has not passed on (tests).
    var streamBacklog: Int { state.withLock { $0.queued } }
}
