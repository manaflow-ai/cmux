import CmuxLink
@testable import CmuxLinkDirect
import Foundation
import os
import Testing

@Suite("Direct writer cancellation")
struct DirectWriterTests {
    @Test("cancelled bulk admission resumes without cancelling the active socket")
    func cancellationWhileWaitingForAdmission() async throws {
        let (admissionStream, admissionSink) = AsyncStream.makeStream(of: Void.self)
        try await withWriter(admissionWaitObserver: { admissionSink.yield(()) }) { socket, writer, frame in
            let active = Task { try await writer.write(frame) }
            await socket.waitForSendStart()

            let waiting = Task { try await writer.write(frame) }
            let admission = Task {
                var iterator = admissionStream.makeAsyncIterator()
                return await iterator.next()
            }
            _ = try await within(.seconds(1)) { try await admission.value }

            waiting.cancel()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await waiting.value }
            }
            #expect(!socket.wasCancelled)

            socket.releaseSends()
            try await within(.seconds(1)) { try await active.value }
        }
    }

    @Test("already cancelled bulk admission does not strand a waiter")
    func cancellationBeforeAdmissionContinuation() async throws {
        try await withWriter { socket, writer, frame in
            let active = Task { try await writer.write(frame) }
            await socket.waitForSendStart()

            let gate = AdmissionGate()
            let cancelled = Task {
                await gate.wait()
                try await writer.write(frame)
            }
            // Open only after cancellation. The write therefore enters the
            // admission continuation already canceled, without ever appending
            // an admission waiter.
            cancelled.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await cancelled.value }
            }
            #expect(!socket.wasCancelled)

            socket.releaseSends()
            try await within(.seconds(1)) { try await active.value }
        }
    }

    @Test("cancelling an active frame cancels the socket and resumes its write")
    func cancellationOfActiveFrame() async throws {
        try await withWriter { socket, writer, frame in
            let active = Task { try await writer.write(frame) }
            await socket.waitForSendStart()

            active.cancel()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await active.value }
            }
            #expect(socket.wasCancelled)
        }
    }

    private func bulkFrame() -> TransportFrame {
        TransportFrame(
            lane: TransportLane(reliability: .reliableOrdered, priority: .bulk),
            bytes: Data(repeating: 0xA5, count: DirectWriter.maxQueuedBulkBytes)
        )
    }

    private func withWriter<T: Sendable>(
        admissionWaitObserver: (@Sendable () -> Void)? = nil,
        _ operation: @Sendable (BlockingWriterSocket, DirectWriter, TransportFrame) async throws -> T
    ) async throws -> T {
        let socket = BlockingWriterSocket()
        let writer = DirectWriter(socket: socket, cipher: NoiseCipherState(),
                                  admissionWaitObserver: admissionWaitObserver)
        do {
            let result = try await operation(socket, writer, bulkFrame())
            socket.cancel()
            await writer.fail()
            return result
        } catch {
            socket.cancel()
            await writer.fail()
            throw error
        }
    }

    private func within<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = CompletionRace<T>()
        let operationTask = Task { try await operation() }
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
        }
        Task {
            do {
                let result = try await operationTask.value
                if await race.finish(.success(result)) { timeoutTask.cancel() }
            } catch {
                if await race.finish(.failure(error)) { timeoutTask.cancel() }
            }
        }
        Task {
            do {
                try await timeoutTask.value
                if await race.finish(.failure(WriterTestTimeout())) { operationTask.cancel() }
            } catch {
                // The operation won the race or the enclosing test canceled.
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                Task { await race.install(continuation) }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task { _ = await race.finish(.failure(CancellationError())) }
        }
    }
}

private struct WriterTestTimeout: Error {}

private actor CompletionRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        if let pending {
            self.pending = nil
            continuation.resume(with: pending)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<Value, any Error>) -> Bool {
        guard !finished else { return false }
        finished = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pending = result
        }
        return true
    }
}

private actor AdmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// Blocks `send` after recording that the writer reached the socket. The
/// first admitted frame therefore keeps the bulk budget occupied while the
/// second write exercises cancellation of the admission continuation.
private final class BlockingWriterSocket: DirectWriterSocket, @unchecked Sendable {
    private struct State {
        var sends: [CheckedContinuation<Void, any Error>] = []
        var cancelled = false
        var released = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startedStream: AsyncStream<Void>
    private let startedSink: AsyncStream<Void>.Continuation

    init() {
        (startedStream, startedSink) = AsyncStream.makeStream(of: Void.self)
    }

    func send(record _: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result = state.withLock { state -> Result<Void, any Error>? in
                if state.cancelled {
                    return .failure(CancellationError())
                }
                if state.released {
                    return .success(())
                }
                state.sends.append(continuation)
                return nil
            }
            if let result {
                continuation.resume(with: result)
            } else {
                // Signal only after registration. This prevents the test from
                // racing the continuation setup in the first send.
                startedSink.yield(())
            }
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
            state.released = true
            defer { state.sends.removeAll() }
            return state.sends
        }
        for continuation in sends { continuation.resume() }
    }
}
