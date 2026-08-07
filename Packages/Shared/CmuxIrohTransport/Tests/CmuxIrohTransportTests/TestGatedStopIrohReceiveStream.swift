import Foundation
@testable import CmuxIrohTransport

actor TestGatedStopIrohReceiveStream: CmxIrohReceiveStream {
    private var buffer: Data
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private let stopStartedStream: AsyncStream<Void>
    private let stopStartedContinuation: AsyncStream<Void>.Continuation

    init(buffer: Data) {
        self.buffer = buffer
        let stopStarted = AsyncStream<Void>.makeStream()
        stopStartedStream = stopStarted.stream
        stopStartedContinuation = stopStarted.continuation
    }

    func receive(maximumByteCount: Int) throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohClientSessionError.invalidMaximumByteCount(
                maximumByteCount
            )
        }
        guard !buffer.isEmpty else { return nil }
        let count = min(maximumByteCount, buffer.count)
        let value = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return value
    }

    func stop(errorCode _: UInt64) async {
        stopStartedContinuation.yield()
        await withCheckedContinuation { continuation in
            stopWaiter = continuation
        }
    }

    func waitUntilStopStarted() async {
        var iterator = stopStartedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseStop() {
        stopWaiter?.resume()
        stopWaiter = nil
    }
}
