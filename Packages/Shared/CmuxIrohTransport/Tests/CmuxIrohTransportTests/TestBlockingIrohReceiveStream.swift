import Foundation
@testable import CmuxIrohTransport

actor TestBlockingIrohReceiveStream: CmxIrohReceiveStream {
    private var buffer: Data
    private let cancellationUnblocksReceive: Bool
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var cancelled = false
    private var stoppedCodes: [UInt64] = []
    private let blockedStream: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation
    private let stoppedStream: AsyncStream<UInt64>
    private let stoppedContinuation: AsyncStream<UInt64>.Continuation

    init(
        buffer: Data,
        cancellationUnblocksReceive: Bool = true
    ) {
        self.buffer = buffer
        self.cancellationUnblocksReceive = cancellationUnblocksReceive
        let blocked = AsyncStream<Void>.makeStream()
        blockedStream = blocked.stream
        blockedContinuation = blocked.continuation
        let stopped = AsyncStream<UInt64>.makeStream()
        stoppedStream = stopped.stream
        stoppedContinuation = stopped.continuation
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
        blockedContinuation.yield()
        guard cancellationUnblocksReceive else {
            return try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
            }
        }
        try Task.checkCancellation()
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

    func stop(errorCode: UInt64) {
        stoppedCodes.append(errorCode)
        stoppedContinuation.yield(errorCode)
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func blockedEvents() -> AsyncStream<Void> {
        blockedStream
    }

    func observedStoppedCodes() -> [UInt64] {
        stoppedCodes
    }

    func stoppedEvents() -> AsyncStream<UInt64> {
        stoppedStream
    }

    private func cancelWaiter() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
