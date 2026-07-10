import Foundation
@testable import CmuxIrohTransport

actor TestBlockingIrohReceiveStream: CmxIrohReceiveStream {
    private var buffer: Data
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var cancelled = false
    private let blockedStream: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation

    init(buffer: Data) {
        self.buffer = buffer
        let blocked = AsyncStream<Void>.makeStream()
        blockedStream = blocked.stream
        blockedContinuation = blocked.continuation
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohClientSessionError.invalidMaximumByteCount(maximumByteCount)
        }
        if !buffer.isEmpty {
            let count = min(maximumByteCount, buffer.count)
            let value = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return value
        }
        try Task.checkCancellation()
        blockedContinuation.yield()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    func stop(errorCode _: UInt64) {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func blockedEvents() -> AsyncStream<Void> {
        blockedStream
    }

    private func cancelWaiter() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
