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

    public func makeAsyncIterator() -> AsyncThrowingStream<DaemonEventEnvelope, any Error>.Iterator {
        route.takeStream()
        return base.makeAsyncIterator()
    }
}
