import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite(.timeLimit(.minutes(1))) struct LinkDeadlineTests {
    @Test func preCancelledRunDoesNotStartOperation() async throws {
        let starts = DeadlineInvocationCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LinkDeadline.run(timeout: .seconds(1), operation: {
                starts.increment()
                return 1
            })
        }
        do {
            _ = try await task.value
            Issue.record("A pre-cancelled run succeeded")
        } catch is CancellationError {}
        #expect(starts.value == 0)
    }

    @Test func deadlineReturnsDespiteUncancellableIOAndDisposesItsLateResult() async throws {
        let gate = DeadlineGate()
        let abandoned = AsyncStream<Void>.makeStream()
        let discarded = AsyncStream<Int>.makeStream()
        let task = Task {
            try await LinkDeadline.run(
                timeout: .milliseconds(30),
                operation: { await gate.wait() },
                onCancel: { abandoned.continuation.yield(()) },
                onDiscard: { discarded.continuation.yield($0) }
            )
        }
        var started = gate.started.makeAsyncIterator()
        _ = await started.next()
        do {
            _ = try await task.value
            Issue.record("Unanswered I/O succeeded")
        } catch let error as LinkError { #expect(error.code == "reply_timeout") }
        var cleanup = abandoned.stream.makeAsyncIterator()
        _ = await cleanup.next()
        gate.release(7)
        var late = discarded.stream.makeAsyncIterator()
        #expect(await late.next() == 7)
        abandoned.continuation.finish()
        discarded.continuation.finish()
    }

    @Test func cancellationReturnsDespiteUncancellableIO() async throws {
        let gate = DeadlineGate()
        let abandoned = AsyncStream<Void>.makeStream()
        let task = Task {
            try await LinkDeadline.run(timeout: .seconds(60), operation: { await gate.wait() },
                                       onCancel: { abandoned.continuation.yield(()) })
        }
        var started = gate.started.makeAsyncIterator()
        _ = await started.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled I/O succeeded")
        } catch is CancellationError {}
        var cleanup = abandoned.stream.makeAsyncIterator()
        _ = await cleanup.next()
        gate.release(7)
        abandoned.continuation.finish()
    }
}

private final class DeadlineInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Never>?
    private let entered = AsyncStream<Void>.makeStream()
    var started: AsyncStream<Void> { entered.stream }

    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            entered.continuation.yield(())
        }
    }

    func release(_ value: Int) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
        entered.continuation.finish()
    }
}
