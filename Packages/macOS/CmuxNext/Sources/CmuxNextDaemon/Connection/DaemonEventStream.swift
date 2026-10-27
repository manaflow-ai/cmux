/// ``DaemonConnection/events``: the connection's events for its one consumer, in order, ending when
/// the connection closes (throwing what ended it, if anything did). The store takes it
/// (``DaemonConnection/consumeEvents(_:)``); a connection used for requests only drops it
/// (``DaemonConnection/discardEvents()``). Another consumer subscribes
/// (``DaemonConnection/subscribe(filter:limit:)``): a second iteration traps in Debug, since two
/// iterators would each get part of the events.
public struct DaemonEventStream: AsyncSequence, Sendable {
    public typealias Element = DaemonEventEnvelope

    let base: AsyncThrowingStream<DaemonEventEnvelope, any Error>
    let route: DaemonEventRoute

    public func makeAsyncIterator() -> Iterator {
        route.takeStream()
        return Iterator(base: base.makeAsyncIterator(), route: route)
    }

    /// Takes the events in order and tells the route each one is taken, so its reader, waiting past the
    /// stream's byte bound (``DaemonEventRoute``), resumes as the consumer catches up.
    public struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Iterator
        let route: DaemonEventRoute

        public mutating func next() async throws -> DaemonEventEnvelope? {
            guard let envelope = try await base.next() else { return nil }
            route.took()
            return envelope
        }
    }
}
