import CmuxNextCompat
import Dispatch
import Testing
@testable import CmuxNextAgentPane

/// A call that missed its deadline says so, also when its teardown makes the operation fail
/// first. A status call came back `closed` (the teardown cancels its socket, and the cancelled
/// read is EOF) on a loaded run instead of saying it missed its deadline (job 122240111475).
struct AgentPaneDeadlineTests {
    private struct Closed: Error {}

    /// The operation's pending read, which the teardown fails, and a mark that it has thrown.
    private nonisolated final class PendingRead: Sendable {
        private let state = Mutex<(continuation: CheckedContinuation<Int, any Error>?, failed: Bool)>((nil, false))
        let thrown = DispatchSemaphore(value: 0)

        func read() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                let failed = state.withLock { state in
                    if !state.failed { state.continuation = continuation }
                    return state.failed
                }
                if failed { continuation.resume(throwing: Closed()) }
            }
        }

        /// The read is pending.
        var waiting: Bool { state.withLock { $0.continuation != nil } }

        /// The socket's cancel: the read ends with `Closed`.
        func cancel() {
            let continuation = state.withLock { state in
                state.failed = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: Closed())
        }
    }

    /// The teardown holds its thread until the torn-down operation has thrown: run from the
    /// deadline's own task, as before, that failure was the result nearly every time.
    @Test func theTeardownsFailureNeverHidesTheDeadline() async {
        for _ in 0..<20 {
            let read = PendingRead()
            await #expect(throws: AgentPaneDeadlineExceeded(label: "status")) {
                try await withAgentPaneDeadline(.milliseconds(1), label: "status", onTimeout: {
                    read.cancel()
                    _ = read.thrown.blockingWait(timeout: .now() + 5)
                }) {
                    defer { read.thrown.signal() }
                    return try await read.read()
                }
            }
        }
    }

    /// Whether the teardown ran; set from the deadline helper's thread.
    private nonisolated final class Flag: Sendable {
        private let state = Mutex(false)
        var value: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    /// Review of #27012 (P2): a caller cancelled before the deadline (the page's x on a dictation
    /// upload whose finish streams to a peer) cancelled only the deadline's sleeper. The teardown
    /// never ran, so the socket read that ignores cancellation kept the call waiting until the peer
    /// answered, or forever. A cancelled caller now tears the operation down as a missed deadline
    /// does (the socket's cancel), and the call ends.
    @Test func aCancelledCallerTearsTheOperationDown() async throws {
        let read = PendingRead()
        let tornDown = Flag()
        let call = Task {
            try await withAgentPaneDeadline(.seconds(600), label: "status", onTimeout: {
                tornDown.set()
                read.cancel()
            }) {
                try await read.read()
            }
        }
        // The operation is waiting on its read: cancel the caller.
        for _ in 0..<300 where !read.waiting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(read.waiting)
        call.cancel()
        for _ in 0..<300 where !tornDown.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tornDown.value, "the cancelled call's teardown ran (its socket was cancelled)")
        // Unsticks a call whose teardown never ran, so the red run ends instead of hanging.
        if !tornDown.value { read.cancel() }
        let result = await call.result
        #expect((try? result.get()) == nil, "a cancelled call has no answer")
    }

    @Test func anAnswerInTimeIsTheResult() async throws {
        #expect(try await withAgentPaneDeadline(.seconds(600), label: "status") { 7 } == 7)
    }

    @Test func theOperationsOwnFailureInTimeIsKept() async {
        await #expect(throws: Closed.self) {
            try await withAgentPaneDeadline(.seconds(600), label: "status") { () async throws -> Int in throw Closed() }
        }
    }
}
