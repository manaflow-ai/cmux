import CmuxNextCompat

/// Where a ``DaemonConnection``'s events go: its `events` stream, or, once a consumer took them
/// (``DaemonConnection/consumeEvents(_:)``), that consumer, called on the thread that produced each
/// event (the transport's reader for every daemon event).
///
/// Chrome's IO thread hands each IPC message to its listener's task runner with no task in between
/// (ipc/ipc_channel_proxy.cc, `ChannelProxy::Context::OnMessageReceivedNoFilter`). The stream put one
/// Swift cooperative-pool job, at user-initiated, between the user-interactive reader and the store's
/// inbox for every event, so the echo of a person's action waited behind whatever ran on the pool
/// (p02-threads-133).
///
/// Order: the events the stream holds when a consumer takes over are older than any later one, so
/// the route keeps adding to the stream until the consumer has taken all it holds
/// (``deliverQueued(_:)``), then hands each new event to the consumer directly. Every hand-off runs
/// under the route's lock, so the consumer sees one order whichever thread emits.
final class DaemonEventRoute: Sendable {
    /// Takes one event. Called with the route's lock held: it must not block or call back into the
    /// connection.
    typealias Sink = @Sendable (DaemonEventEnvelope) -> Void

    private struct State {
        var sink: Sink?
        /// Events added to the stream that no ``deliverQueued(_:)`` has passed on yet.
        var queued = 0
        var finished = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// Passes `envelope` on: to the consumer when it took the events and the stream holds none it has
    /// not taken, else to the stream. Dropped once the route finished, as a finished stream drops it.
    func emit(_ envelope: DaemonEventEnvelope) {
        state.withLock { state in
            guard !state.finished else { return }
            if let sink = state.sink, state.queued == 0 { return sink(envelope) }
            state.queued += 1
            continuation.yield(envelope)
        }
    }

    /// Makes `sink` the consumer of every later event (after the ones the stream holds).
    func attach(_ sink: @escaping Sink) {
        state.withLock { $0.sink = sink }
    }

    /// Hands an event the consumer took from the stream to its sink, in order with direct ones.
    func deliverQueued(_ envelope: DaemonEventEnvelope) {
        state.withLock { state in
            state.queued = max(state.queued - 1, 0)
            state.sink?(envelope)
        }
    }

    /// Drops the consumer (its stream ended).
    func detach() {
        state.withLock { $0.sink = nil }
    }

    /// Ends the stream: events emitted later are dropped; the ones it holds still reach the consumer.
    func finish(throwing error: (any Error)? = nil) {
        state.withLock { state in
            state.finished = true
            continuation.finish(throwing: error)
        }
    }
}
