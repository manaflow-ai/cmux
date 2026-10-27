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
        return Iterator(base: base.makeAsyncIterator(), consumer: Consumer(route: route))
    }

    /// Takes the events in order and tells the route each one is taken, so its reader, waiting past the
    /// stream's byte bound (``DaemonEventRoute``), resumes as the consumer catches up. When it ends or is
    /// dropped, the reader no longer waits for it.
    public struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Iterator
        let consumer: Consumer

        public mutating func next() async throws -> DaemonEventEnvelope? {
            let envelope: DaemonEventEnvelope?
            do {
                envelope = try await base.next()
            } catch {
                consumer.route.consumerEnded()
                throw error
            }
            guard let envelope else {
                consumer.route.consumerEnded()
                return nil
            }
            consumer.route.took()
            return envelope
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
