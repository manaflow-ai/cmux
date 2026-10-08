import CmuxLink
@testable import CmuxLinkDirect
import Foundation
import os
import Testing

@Suite("Direct writer cancellation")
struct DirectWriterTests {
    @Test("cancelled bulk admission resumes without cancelling the active socket")
    func cancellationWhileWaitingForAdmission() async throws {
        let socket = BlockingWriterSocket()
        let writer = DirectWriter(socket: socket, cipher: NoiseCipherState())
        let frame = bulkFrame()

        let active = Task { try await writer.write(frame) }
        await socket.waitForSendStart()

        let waiting = Task { try await writer.write(frame) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await within(.seconds(1)) { try await waiting.value }
        }
        #expect(!socket.wasCancelled)

        socket.releaseSends()
        try await within(.seconds(1)) { try await active.value }
        await writer.fail()
    }

    @Test("already cancelled bulk admission does not strand a waiter")
    func cancellationBeforeAdmissionContinuation() async throws {
        let socket = BlockingWriterSocket()
        let writer = DirectWriter(socket: socket, cipher: NoiseCipherState())
        let frame = bulkFrame()

        let active = Task { try await writer.write(frame) }
        await socket.waitForSendStart()

        let cancelled = Task { try await writer.write(frame) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await within(.seconds(1)) { try await cancelled.value }
        }
        #expect(!socket.wasCancelled)

        socket.releaseSends()
        try await within(.seconds(1)) { try await active.value }
        await writer.fail()
    }

    private func bulkFrame() -> TransportFrame {
        TransportFrame(
            lane: TransportLane(reliability: .reliableOrdered, priority: .bulk),
            bytes: Data(repeating: 0xA5, count: DirectWriter.maxQueuedBulkBytes)
        )
    }

    private func within<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WriterTestTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private struct WriterTestTimeout: Error {}

/// Blocks `send` after recording that the writer reached the socket. The
/// first admitted frame therefore keeps the bulk budget occupied while the
/// second write exercises cancellation of the admission continuation.
private final class BlockingWriterSocket: DirectWriterSocket, @unchecked Sendable {
    private struct State {
        var sends: [CheckedContinuation<Void, any Error>] = []
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startedStream: AsyncStream<Void>
    private let startedSink: AsyncStream<Void>.Continuation

    init() {
        (startedStream, startedSink) = AsyncStream.makeStream(of: Void.self)
    }

    func send(record _: Data) async throws {
        startedSink.yield(())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let cancelled = state.withLock { state in
                if state.cancelled {
                    return true
                }
                state.sends.append(continuation)
                return false
            }
            if cancelled { continuation.resume(throwing: CancellationError()) }
        }
    }

    func cancel() {
        let sends = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.cancelled = true
            defer { state.sends.removeAll() }
            return state.sends
        }
        for continuation in sends { continuation.resume(throwing: CancellationError()) }
    }

    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func waitForSendStart() async {
        var iterator = startedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseSends() {
        let sends = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            defer { state.sends.removeAll() }
            return state.sends
        }
        for continuation in sends { continuation.resume() }
    }
}
