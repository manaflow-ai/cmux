import CmuxNextCompat
import Dispatch
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
/// inbox for every event, so the echo of a person's action waited behind whatever ran on the pool.
/// The other consumers are the IO thread's message filters
/// (`ChannelProxy::Context::AddFilter`): each sees every message on the reader, in order, and none
/// waits for another.
///
/// Bounded: nothing here grows with the events no one took. The backlog is an
/// ``EventInbox`` that holds at most 4096 events of every kind, collapsed or not
/// (``EventInbox/Retention/upToLimit``: coalescing, one `overflow` marker that the store answers
/// with one resync), as mojo bounds what a receiver leaves unread
/// (`MOJO_QUOTA_TYPE_UNREAD_MESSAGE_COUNT`, mojo/public/cpp/bindings/message_quota_checker.h);
/// where mojo ends the pipe at its quota, the consumer re-reads. A sink that attaches takes the backlog first, under the route's lock, so it
/// sees one order with the events emitted after it.
///
/// Backpressure: the reader counts the line bytes of each event it adds to the
/// backlog. Past ``highWater`` bytes, while a live stream consumer reads it, the reader thread waits,
/// after the line and outside its hang scope (``waitWhileReaderParked()``), until the consumer takes
/// the backlog, so the socket stops draining and the daemon's bounded outbound queue (cmux-tui-core
/// server/bounded_outbound.rs) applies its budget before the backlog collapses: Mojo's data pipe gives
/// a producer the same `MOJO_RESULT_SHOULD_WAIT` (mojo/core/data_pipe_producer_dispatcher.cc). The
/// reader waits only for a live consumer, as an attach connection's reader waits only once the view
/// attached (``TerminalEventQueue``): before one takes the stream (its owner first sends requests on
/// this connection, whose replies this reader reads), after it stopped taking (its iterator ended or
/// was dropped) and while a sink takes each event, the reader never waits; there the backlog's count
/// bound alone holds. Events the actor emits (`connected`, `disconnected`) never wait.
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
        /// Set by the stream's first consumer (``takeStream(iterating:)``).
        var streamTaken = false
        /// The stream's consumer is an iterator (``DaemonEventStream``), not a sink: the one consumer the
        /// reader waits for.
        var streamIterated = false
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
        /// The line bytes of the events added to the backlog since a consumer last took it: at least
        /// what it holds (a coalesced or collapsed event stays counted until the take).
        var backlogBytes = 0
        /// The stream's consumer stopped taking it (its iterator ended or was dropped): nothing is
        /// taken again, so later events are dropped and the reader never waits for it.
        var consumerGone = false
        /// The reader waits on `readerWake`; whoever clears this signals it exactly once. Only the reader
        /// sets it, and only when it is clear, so each set pairs with exactly one wait.
        var readerParked = false
        /// An emit parked the reader; its ``DaemonEventRoute/waitWhileReaderParked()`` waits once for it.
        var readerOwesWait = false

        /// Whether the reader must wait now: a live stream consumer has more than `highWater` bytes
        /// to take.
        func mustPark(above highWater: Int) -> Bool {
            streamIterated && sink == nil && !consumerGone && !finished && backlogBytes > highWater
        }

        /// Clears the parked mark; true when the caller must signal the reader.
        mutating func releaseReader() -> Bool {
            defer { readerParked = false }
            return readerParked
        }
    }

    /// The events no sink took yet: at most the limit, coalescing, collapsed past it into one
    /// `overflow` marker plus what a resync cannot restore while that fits (``EventInbox``).
    let backlog: EventInbox
    /// The backlog's bytes past which the reader waits for a live stream consumer to take it.
    let highWater: Int
    private let state = Mutex(State())
    // concurrency-allow: the designed backpressure that makes the daemon's bounded outbound queue act: only the
    // control connection's dedicated reader thread (LineTransport) waits on it, never the main thread or a pool thread.
    private let readerWake = DispatchSemaphore(value: 0)
    /// Called on the reader thread each time it starts to wait past ``highWater``, before it waits and
    /// outside any hang scope. Tests use it to see the backpressure without timing; it must not block.
    private let onReaderParked: (@Sendable () -> Void)?

    init(limit: Int = EventInbox.defaultLimit, highWater: Int = 8 << 20, onReaderParked: (@Sendable () -> Void)? = nil) {
        backlog = EventInbox(limit: limit, retention: .upToLimit)
        self.highWater = max(highWater, 1)
        self.onReaderParked = onReaderParked
    }

    /// Passes `envelope` on: to each subscriber it matches, and to the sink when one took the events,
    /// else to the backlog. Dropped once the route finished, or once the stream's consumer stopped
    /// taking it. Never waits.
    ///
    /// - Parameters:
    ///   - bytes: The event's line bytes, counted until a consumer takes the backlog.
    ///   - parksReader: True only for an event the reader routed (its handler runs on the connection's decode
    ///     lane): past ``highWater`` it marks the reader parked, and the reader waits in
    ///     ``waitWhileReaderParked()`` after a line it handles.
    func emit(_ envelope: DaemonEventEnvelope, bytes: Int = 0, parksReader: Bool = false) {
        let (woken, release) = state.withLock { state -> ((OnceContinuation<Step, OnceContinuationError>, Step)?, Bool) in
            guard !state.finished else { return (nil, false) }
            for subscriber in state.subscribers { subscriber.inbox.offer(envelope) }
            if let sink = state.sink {
                sink(envelope)
                return (nil, false)
            }
            guard !state.consumerGone else { return (nil, false) }
            _ = backlog.append(envelope)
            state.backlogBytes += max(bytes, 0)
            if let waiter = state.waiter, waiter.takesEvents {
                state.waiter = nil
                let batch = takeBacklog(&state)
                return ((waiter.continuation, .events(batch)), state.releaseReader())
            }
            if parksReader, !state.readerOwesWait, !state.readerParked, state.mustPark(above: highWater) {
                state.readerParked = true
                state.readerOwesWait = true
            }
            return (nil, false)
        }
        if release { readerWake.signal() }
        if case let (continuation, step)? = woken { continuation.resume(returning: step) }
    }

    /// Takes what the backlog holds; its bytes are taken with it. Called with the route's lock held;
    /// the caller releases a parked reader (``State/releaseReader()``).
    private func takeBacklog(_ state: inout State) -> [DaemonEventEnvelope] {
        state.backlogBytes = 0
        return backlog.take()
    }

    /// The reader's backpressure wait, after it handled a line and outside the line's hang scope
    /// (`LineTransport`'s ``EventDispatch/readerWait``): when an emit parked it, it waits until the consumer has
    /// taken the backlog, stopped taking it, a sink took over, or the route finished. Returns at once
    /// otherwise.
    func waitWhileReaderParked() {
        let owed = state.withLock { state -> Bool in
            defer { state.readerOwesWait = false }
            return state.readerOwesWait
        }
        guard owed else { return }
        onReaderParked?()
        var waiting = true
        while waiting {
            // The designed backpressure (see the type): a checked wait, only on the control connection's
            // dedicated reader thread (LineTransport), never the main thread or a pool thread.
            readerWake.blockingWait()
            waiting = state.withLock { state -> Bool in
                guard state.mustPark(above: highWater) else { return false }
                state.readerParked = true
                return true
            }
        }
    }

    /// The stream's consumer stopped taking it: its iterator ended (the route finished, or its task was
    /// cancelled) or was dropped. What the backlog holds is dropped, later events are too, and a waiting
    /// reader resumes.
    func consumerEnded() {
        let release = state.withLock { state -> Bool in
            state.consumerGone = true
            _ = takeBacklog(&state)
            return state.releaseReader()
        }
        if release { readerWake.signal() }
    }

    /// Marks the stream taken by its one consumer (the store, or the connection's only reader). A
    /// second consumer would split the events with the first, so it traps in Debug.
    ///
    /// - Parameter iterating: The consumer reads the stream with an iterator (``DaemonEventStream``),
    ///   which the reader waits for past ``highWater`` until it ends (``consumerEnded()``).
    func takeStream(iterating: Bool = false) {
        let first = state.withLock { state -> Bool in
            let first = !state.streamTaken
            state.streamTaken = true
            if first, iterating { state.streamIterated = true }
            return first
        }
        assert(first, "DaemonConnection.events has one consumer; take another with subscribe(filter:limit:)")
    }

    /// Makes `sink` the consumer of every later event, after it took what the backlog holds.
    func attach(_ sink: @escaping Sink) {
        let release = state.withLock { state -> Bool in
            for envelope in takeBacklog(&state) { sink(envelope) }
            state.sink = sink
            return state.releaseReader()
        }
        if release { readerWake.signal() }
    }

    /// Takes the stream and drops every event it would get, the held ones too; subscribers still get
    /// theirs.
    func discardStream() {
        takeStream()
        let (replaced, release) = state.withLock { state -> (Sink?, Bool) in
            let replaced = state.sink
            state.sink = { _ in }
            _ = takeBacklog(&state)
            return (replaced, state.releaseReader())
        }
        if release { readerWake.signal() }
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
                let (ready, release) = state.withLock { state -> (Step?, Bool) in
                    let batch = takingEvents ? takeBacklog(&state) : []
                    if !batch.isEmpty { return (.events(batch), state.releaseReader()) }
                    if state.finished { return (state.end(), false) }
                    assert(state.waiter == nil, "DaemonConnection.events has one consumer")
                    state.waiter = Waiter(continuation: continuation, takesEvents: takingEvents)
                    return (nil, false)
                }
                if release { readerWake.signal() }
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
    /// the consumer's wait throws. A waiting reader resumes.
    func finish(throwing error: DaemonError? = nil) {
        let (inboxes, woken, release) = state.withLock { state -> ([DaemonEventSubscription.Inbox], (OnceContinuation<Step, OnceContinuationError>, Step)?, Bool) in
            if !state.finished {
                state.finished = true
                state.failure = error
            }
            let inboxes = state.subscribers.map(\.inbox)
            state.subscribers.removeAll()
            let release = state.releaseReader()
            // A waiting consumer found the backlog empty, and every later event woke it.
            guard let waiter = state.waiter else { return (inboxes, nil, release) }
            state.waiter = nil
            return (inboxes, (waiter.continuation, state.end()), release)
        }
        if release { readerWake.signal() }
        for inbox in inboxes { inbox.finish() }
        if case let (continuation, step)? = woken { continuation.resume(returning: step) }
    }

    /// Subscribers the route delivers to now (tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Events in the backlog that no consumer took yet (tests).
    var streamBacklog: Int { backlog.bufferedCount }

    /// Line bytes counted for the backlog since a consumer last took it (tests).
    var streamBacklogBytes: Int { state.withLock { $0.backlogBytes } }

    /// True while the reader waits for the consumer (tests).
    var isReaderParked: Bool { state.withLock { $0.readerParked } }
}
