/// A single-consumer worker event stream with explicit byte and count ceilings.
/// Events are delivered directly to a waiting consumer; only producer bursts
/// consume the bounded buffer.
public struct SimulatorWorkerEventStream: AsyncSequence, Sendable {
    /// Event delivered by the stream.
    public typealias Element = SimulatorWorkerEvent
    /// Iterator used to consume worker events.
    public typealias AsyncIterator = SimulatorWorkerEventStreamAsyncIterator
    /// Producer handle paired with a stream source.
    public typealias Continuation = SimulatorWorkerEventStreamContinuation
    /// Result of attempting to enqueue an event.
    public typealias YieldResult = SimulatorWorkerEventStreamYieldResult

    let storage: SimulatorWorkerEventStreamStorage
    let lifetime: SimulatorWorkerEventStreamLifetime

    init(
        storage: SimulatorWorkerEventStreamStorage,
        lifetime: SimulatorWorkerEventStreamLifetime
    ) {
        self.storage = storage
        self.lifetime = lifetime
    }

    /// Creates an iterator retaining this subscription until iteration ends.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage, lifetime: lifetime)
    }
}
