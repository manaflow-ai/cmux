import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    static let defaultPendingOperationLimit = 512

    private let continuation: AsyncStream<MobileDebugLogOperation>.Continuation

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        // Clear is a privacy/session boundary, so queue operations must not be
        // dropped or reordered. Retained diagnostics remain bounded by
        // MobileDebugLogSink.capacity; this mailbox only preserves write order.
        _ = pendingOperationLimit
        let stream = AsyncStream.makeStream(
            of: MobileDebugLogOperation.self,
            bufferingPolicy: .unbounded
        )
        self.continuation = stream.continuation
        Task.detached {
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
        return Task.detached {
            var iterator = receipt.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func yield(_ operation: MobileDebugLogOperation) {
        continuation.yield(operation)
    }
}
