import CmuxIrohTransport
import Foundation

actor BridgeServerEventReceiveFixture: CmxIrohReceiveStream {
    struct Failure: Error {}
    var chunks: [Data]
    let fails: Bool
    let stopEvents = AsyncStream<UInt64>.makeStream()

    init(chunks: [Data], fails: Bool) {
        self.chunks = chunks
        self.fails = fails
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if fails { throw Failure() }
        return nil
    }

    func stop(errorCode: UInt64) async {
        stopEvents.continuation.yield(errorCode)
    }

    func firstStop() async -> UInt64? {
        var iterator = stopEvents.stream.makeAsyncIterator()
        return await iterator.next()
    }
}
