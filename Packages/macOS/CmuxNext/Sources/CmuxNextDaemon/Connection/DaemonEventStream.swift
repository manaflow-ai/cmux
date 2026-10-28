/// ``DaemonConnection/events``: the connection's events for its one consumer, in order, ending when
/// the connection closes (throwing what ended it, if anything did). The store takes it
/// (``DaemonConnection/consumeEvents(_:)``); a connection used for requests only drops it
/// (``DaemonConnection/discardEvents()``). Another consumer subscribes
/// (``DaemonConnection/subscribe(filter:limit:)``): a second iteration traps in Debug, since two
/// iterators would each get part of the events.
///
/// Bounded: the events wait in the route's ``EventInbox`` backlog, so a reader that
/// falls more than 4096 events behind gets one ``DaemonEvent/overflow(_:)`` in place of the ones it
/// lost and must re-read; the backlog never holds more than 4096 events of any kind (lifecycle
/// events and what a re-read cannot restore are kept while they fit, then only the newest of each
/// lifecycle event), and whole-value surface events it has not read yet coalesce to the newest.
/// Before that, past the route's byte bound, the connection's reader waits for this consumer
/// (``DaemonEventRoute``), so the daemon's bounded outbound queue applies its budget first.
public struct DaemonEventStream: AsyncSequence, Sendable {
    public typealias Element = DaemonEventEnvelope

    let route: DaemonEventRoute

    public func makeAsyncIterator() -> Iterator {
        route.takeStream(iterating: true)
        return Iterator(consumer: Consumer(route: route))
    }

    /// Takes the route's backlog a batch at a time and yields it in order; each take lets the
    /// route's reader, waiting past the byte bound, resume. When it ends or is dropped, the reader no
    /// longer waits for it.
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = DaemonEventEnvelope
        public typealias Failure = any Error

        let consumer: Consumer
        private var batch: IndexingIterator<[DaemonEventEnvelope]> = [DaemonEventEnvelope]().makeIterator()

        init(consumer: Consumer) {
            self.consumer = consumer
        }

        /// The next event; nil once the connection closed and every event was read, or once the
        /// consuming task is cancelled. Throws, once, what ended the connection.
        public mutating func next() async throws -> DaemonEventEnvelope? {
            if let envelope = batch.next() { return envelope }
            let next: [DaemonEventEnvelope]?
            do {
                next = try await consumer.route.nextBatch()
            } catch {
                consumer.route.consumerEnded()
                throw error
            }
            // A batch is never empty.
            guard let next else {
                consumer.route.consumerEnded()
                return nil
            }
            batch = next.makeIterator()
            return batch.next()
        }
    }

    /// The live consumer of the stream: the last copy of its iterator going away ends it.
    final class Consumer: Sendable {
        let route: DaemonEventRoute

        init(route: DaemonEventRoute) {
            self.route = route
        }

        deinit {
            route.consumerEnded()
        }
    }
}
