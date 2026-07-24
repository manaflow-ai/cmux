import CmuxControlSocket

struct TestSocketRecoveryClock: SocketRecoveryClock {
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        stream = pair.stream
    }

    func sleep(forMilliseconds milliseconds: Int) async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    func advance() {
        continuation.yield()
    }
}
