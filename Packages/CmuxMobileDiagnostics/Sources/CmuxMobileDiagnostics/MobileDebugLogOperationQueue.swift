import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    static let defaultPendingOperationLimit = 512

    private let continuation: AsyncStream<MobileDebugLogOperation>.Continuation
    private let sink: MobileDebugLogSink

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        let stream = AsyncStream.makeStream(
            of: MobileDebugLogOperation.self,
            bufferingPolicy: .bufferingNewest(max(1, pendingOperationLimit))
        )
        self.sink = sink
        self.continuation = stream.continuation
        Task {
            for await operation in stream.stream {
                await operation.run(on: sink)
            }
        }
    }

    func append(_ message: String) {
        yield(.append(message))
    }

    func clear() -> Task<Void, Never> {
        let receipt = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        yield(.clear(receipt.continuation))
        return Task {
            var iterator = receipt.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func yield(_ operation: MobileDebugLogOperation) {
        switch continuation.yield(operation) {
        case .enqueued, .terminated:
            break
        case .dropped(let dropped):
            dropped.runIfDropped(from: sink)
        @unknown default:
            break
        }
    }
}
