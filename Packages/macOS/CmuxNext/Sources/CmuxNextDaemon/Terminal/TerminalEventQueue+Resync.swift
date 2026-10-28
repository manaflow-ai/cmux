extension TerminalEventQueue {
    /// What a push does once the consumer is `highWater` output bytes behind.
    enum Backpressure: Sendable {
        /// Park the reader thread until the consumer drains to `lowWater` (the per-view connection).
        case parkReader
        /// Never wait. Drop the queued output a fresh READY supersedes and drop such output until that
        /// READY. The request runs outside the queue's lock and must not block (it enqueues the
        /// `snapshot-request`); its answer comes back through its completion. A byte attach has no
        /// READY to ask for, so it ends with `closed(.overflow)` instead and the view reattaches.
        case dropAndResync(ResyncRequest)
    }

    /// Sends one `snapshot-request` and reports the daemon's answer to `completion` once, on any thread.
    typealias ResyncRequest = @Sendable (_ completion: @escaping @Sendable (ResyncOutcome) -> Void) -> Void

    /// The daemon's answer to a resync's `snapshot-request`.
    enum ResyncOutcome: Sendable, Equatable {
        /// A READY is coming (accepted, or collapsed into one already pending).
        case accepted
        /// The view got a snapshot too recently: the queue asks again after `retryAfter`.
        case throttled(retryAfter: Duration)
        /// No READY will come (an error reply, or the connection closed).
        case failed
    }

    /// Where a ``Backpressure/dropAndResync(_:)`` queue is in recovering from an overflow.
    enum ResyncPhase: Sendable, Equatable {
        case idle
        /// An overflow while a fresh state (READY, replay, resize) waited for the consumer: output after
        /// it is dropped, and the request goes out when the consumer takes that state.
        case deferred
        /// The `snapshot-request` is out: output a READY supersedes is dropped until one arrives.
        case awaitingReady
    }
}
