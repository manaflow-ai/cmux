import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    private enum Operation: Sendable {
        case append(String)
        case clear(AsyncStream<Void>.Continuation)

        func run(on sink: MobileDebugLogSink) async {
            switch self {
            case .append(let message):
                await sink.append(message)
            case .clear(let receipt):
                await sink.clear()
                receipt.yield(())
                receipt.finish()
            }
        }

        func runIfDropped(from sink: MobileDebugLogSink) {
            guard case .clear = self else { return }
            Task {
                await run(on: sink)
            }
        }
    }

    static let defaultPendingOperationLimit = 512

    private let continuation: AsyncStream<Operation>.Continuation
    private let sink: MobileDebugLogSink

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        let stream = AsyncStream.makeStream(
            of: Operation.self,
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

    private func yield(_ operation: Operation) {
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
