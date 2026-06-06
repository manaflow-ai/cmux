import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    private typealias Operation = @Sendable () async -> Void

    private let continuation: AsyncStream<Operation>.Continuation
    private let sink: MobileDebugLogSink

    init(sink: MobileDebugLogSink) {
        let stream = AsyncStream.makeStream(of: Operation.self)
        self.sink = sink
        self.continuation = stream.continuation
        Task {
            for await operation in stream.stream {
                await operation()
            }
        }
    }

    func append(_ message: String) {
        let sink = sink
        continuation.yield {
            await sink.append(message)
        }
    }

    func clear() -> Task<Void, Never> {
        let sink = sink
        let receipt = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield {
            await sink.clear()
            receipt.continuation.yield(())
            receipt.continuation.finish()
        }
        return Task {
            var iterator = receipt.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
}
