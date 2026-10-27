/// ``DaemonConnection/events``: the connection's events for its one consumer, in order, ending when
/// the connection closes (throwing what ended it, if anything did). The store takes it
/// (``DaemonConnection/consumeEvents(_:)``); a connection used for requests only drops it
/// (``DaemonConnection/discardEvents()``). Another consumer subscribes
/// (``DaemonConnection/subscribe(filter:limit:)``): a second iteration traps in Debug, since two
/// iterators would each get part of the events.
///
/// Bounded (p05-ipc-093): the events wait in the route's ``EventInbox`` backlog, so a reader that
/// falls more than 4096 events behind gets one ``DaemonEvent/overflow(_:)`` in place of the ones it
/// lost and must re-read; the backlog never holds more than 4096 events of any kind (lifecycle
/// events and what a re-read cannot restore are kept while they fit, then only the newest of each
/// lifecycle event), and whole-value surface events it has not read yet coalesce to the newest.
public struct DaemonEventStream: AsyncSequence, Sendable {
    public typealias Element = DaemonEventEnvelope

    let route: DaemonEventRoute

    public func makeAsyncIterator() -> Iterator {
        route.takeStream()
        return Iterator(route: route)
    }

    /// Takes the route's backlog a batch at a time and yields it in order.
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = DaemonEventEnvelope
        public typealias Failure = any Error

        let route: DaemonEventRoute
        private var batch: IndexingIterator<[DaemonEventEnvelope]> = [DaemonEventEnvelope]().makeIterator()

        init(route: DaemonEventRoute) {
            self.route = route
        }

        /// The next event; nil once the connection closed and every event was read, or once the
        /// consuming task is cancelled. Throws, once, what ended the connection.
        public mutating func next() async throws -> DaemonEventEnvelope? {
            if let envelope = batch.next() { return envelope }
            // A batch is never empty.
            guard let next = try await route.nextBatch() else { return nil }
            batch = next.makeIterator()
            return batch.next()
        }
    }
}
