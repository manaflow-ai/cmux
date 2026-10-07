/// The inbound event sequence of one channel.
public struct ChannelEvents: AsyncSequence, Sendable {
    public typealias Element = ChannelEvent

    let session: LinkSession
    let channel: UInt32
    let incarnation: UInt64

    public struct AsyncIterator: AsyncIteratorProtocol {
        let session: LinkSession
        let channel: UInt32
    let incarnation: UInt64

        public mutating func next() async -> ChannelEvent? {
            await session.channelNextEvent(channel, incarnation)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(session: session, channel: channel, incarnation: incarnation)
    }
}
