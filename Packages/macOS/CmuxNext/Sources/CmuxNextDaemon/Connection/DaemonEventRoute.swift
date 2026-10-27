import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Where a ``DaemonConnection``'s events go: its one consumer, and each event a subscriber's filter
/// matches into that subscriber's bounded inbox (``DaemonEventSubscription``). The consumer either
/// took the events with a sink (``DaemonConnection/consumeEvents(_:)``, the store), called on the
/// thread that produced each event (the transport's reader for every daemon event), or reads them as
/// a stream (``DaemonConnection/events``). Until a sink takes them, events wait in ``backlog``.
///
/// Chrome's IO thread hands each IPC message to its listener's task runner with no task in between
/// (ipc/ipc_channel_proxy.cc, `ChannelProxy::Context::OnMessageReceivedNoFilter`). A stream put one
/// Swift cooperative-pool job, at user-initiated, between the user-interactive reader and the store's
/// inbox for every event, so the echo of a person's action waited behind whatever ran on the pool
/// (p02-threads-133). The other consumers are the IO thread's message filters
/// (`ChannelProxy::Context::AddFilter`): each sees every message on the reader, in order, and none
/// waits for another.
///
/// Bounded (p05-ipc-093): nothing here grows with the events no one took. The backlog is an
/// ``EventInbox`` (4096 events, coalescing, one `overflow` marker that the store answers with one
/// resync), as mojo bounds what a receiver leaves unread (`MOJO_QUOTA_TYPE_UNREAD_MESSAGE_COUNT`,
/// mojo/public/cpp/bindings/message_quota_checker.h); where mojo ends the pipe at its quota, the
/// consumer re-reads. A sink that attaches takes the backlog first, under the route's lock, so it
/// sees one order with the events emitted after it.
final class DaemonEventRoute: Sendable {
    /// Takes one event. Called with the route's lock held: it must not block or call back into the
    /// connection.
    typealias Sink = @Sendable (DaemonEventEnvelope) -> Void

    private struct Subscriber {
        let id: UInt64
        let inbox: DaemonEventSubscription.Inbox
    }

    /// What the consumer's wait finds.
    private enum Step: Sendable {
        /// Events the backlog held, in order; never empty.
        case events([DaemonEventEnvelope])
        /// The route finished; the failure that ended it, reported once.
        case ended(DaemonError?)
    }

    /// The consumer waiting for an event or the end.
    private struct Waiter {
        let continuation: OnceContinuation<Step, OnceContinuationError>
        /// A stream reader takes the backlog's events; a sink's consumer waits only for the end.
        let takesEvents: Bool
    }

    private struct State {
        var sink: Sink?
        var finished = false
        var failure: DaemonError?
        /// Set by the stream's first consumer (``takeStream()``).
        var streamTaken = false
        /// The consumer waiting for an event or the end; set only while it found neither.
        var waiter: Waiter?

        /// The route's end for the waiting consumer: the failure, reported once.
        mutating func end() -> Step {
            defer { failure = nil }
            return .ended(failure)
        }
        /// The subscribers in the order they came.
        var subscribers: [Subscriber] = []
        var lastSubscriberID: UInt64 = 0
    }

    /// The events no sink took yet: bounded, coalescing, collapsed past its limit into one
    /// `overflow` marker plus what a resync cannot restore (``EventInbox``).
    let backlog: EventInbox
    private let state = Mutex(State())

    init(limit: Int = EventInbox.defaultLimit) {
        backlog = EventInbox(limit: limit)
    }

    /// Passes `envelope` on: to each subscriber it matches, and to the sink when one took the events,
    /// else to the backlog. Dropped once the route finished.
    func emit(_ envelope: DaemonEventEnvelope) {
        let woken = state.withLock { state -> (OnceContinuation<Step, OnceContinuationError>, Step)? in
            guard !state.finished else { return nil }
            for subscriber in state.subscribers { subscriber.inbox.offer(envelope) }
            if let sink = state.sink {
                sink(envelope)
                return nil
            }
            _ = backlog.append(envelope)
            guard let waiter = state.waiter, waiter.takesEvents else { return nil }
            state.waiter = nil
            return (waiter.continuation, .events(backlog.take()))
        }
        if case let (continuation, step)? = woken { continuation.resume(returning: step) }
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

    /// Makes `sink` the consumer of every later event, after it took what the backlog holds.
    func attach(_ sink: @escaping Sink) {
        state.withLock { state in
            for envelope in backlog.take() { sink(envelope) }
            state.sink = sink
        }
    }

    /// Takes the stream and drops every event it would get, the held ones too; subscribers still get
    /// theirs.
    func discardStream() {
        takeStream()
        let replaced = state.withLock { state -> Sink? in
            let replaced = state.sink
            state.sink = { _ in }
            _ = backlog.take()
            return replaced
        }
        withExtendedLifetime(replaced) {}
    }

    /// Drops the sink (its consumer ended); later events wait in the backlog again. The sink is
    /// released after the unlock: the last reference to a subscription it holds ends that
    /// subscription, which takes the lock.
    func detach() {
        let sink = state.withLock { state -> Sink? in
            let sink = state.sink
            state.sink = nil
            return sink
        }
        withExtendedLifetime(sink) {}
    }

    /// The events the backlog holds, waiting while it holds none; nil once the route finished and
    /// they were all taken, or once the waiting task is cancelled. Throws, once, what ended the route.
    func nextBatch() async throws(DaemonError) -> [DaemonEventEnvelope]? {
        try await wait(takingEvents: true)
    }

    /// Returns when the route finishes (or the waiting task is cancelled), throwing what ended it:
    /// the wait of a consumer whose sink takes every event.
    func ended() async throws(DaemonError) {
        _ = try await wait(takingEvents: false)
    }

    /// One wait: resumed by the first event emitted into the backlog (`takingEvents`) or by the route's
    /// end, each handing over what it found.
    private func wait(takingEvents: Bool) async throws(DaemonError) -> [DaemonEventEnvelope]? {
        guard !Task.isCancelled else { return cancelledWait() }
        let step: Step
        do {
            step = try await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }) {
                (continuation: OnceContinuation<Step, OnceContinuationError>) in
                let ready = state.withLock { state -> Step? in
                    let batch = takingEvents ? backlog.take() : []
                    if !batch.isEmpty { return .events(batch) }
                    if state.finished { return state.end() }
                    assert(state.waiter == nil, "DaemonConnection.events has one consumer")
                    state.waiter = Waiter(continuation: continuation, takesEvents: takingEvents)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } catch {
            return cancelledWait()
        }
        switch step {
        case .events(let batch): return batch
        case .ended(let failure?): throw failure
        case .ended(nil): return nil
        }
    }

    /// A cancelled consumer's stream ends, as an `AsyncThrowingStream`'s does; its wait leaves.
    private func cancelledWait() -> [DaemonEventEnvelope]? {
        state.withLock { $0.waiter = nil }
        return nil
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

    /// Ends the stream and every subscription: events emitted later are dropped; the ones the
    /// backlog and each inbox hold still reach their consumers. The first call's `error` is what
    /// the consumer's wait throws.
    func finish(throwing error: DaemonError? = nil) {
        let (inboxes, woken) = state.withLock { state -> ([DaemonEventSubscription.Inbox], (OnceContinuation<Step, OnceContinuationError>, Step)?) in
            if !state.finished {
                state.finished = true
                state.failure = error
            }
            let inboxes = state.subscribers.map(\.inbox)
            state.subscribers.removeAll()
            // A waiting consumer found the backlog empty, and every later event woke it.
            guard let waiter = state.waiter else { return (inboxes, nil) }
            state.waiter = nil
            return (inboxes, (waiter.continuation, state.end()))
        }
        for inbox in inboxes { inbox.finish() }
        if case let (continuation, step)? = woken { continuation.resume(returning: step) }
    }

    /// Subscribers the route delivers to now (tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Events in the backlog that no consumer took yet (tests).
    var streamBacklog: Int { backlog.bufferedCount }
}
