import CmuxNextCompat
import Dispatch
import Testing
@testable import CmuxNextAgentPane

/// A call that missed its deadline says so, also when its teardown makes the operation fail
/// first. A hung acpmux's status call came back `closed` (the teardown cancels its socket, and the
/// cancelled read is EOF) on a loaded run, so the miss was not counted and the hung daemon kept
/// running (AcpmuxUnresponsiveRestartTests.aHungDaemonGetsSigtermAndANewDaemonStarts, job 122240111475).
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

    @Test func anAnswerInTimeIsTheResult() async throws {
        #expect(try await withAgentPaneDeadline(.seconds(600), label: "status") { 7 } == 7)
    }

    @Test func theOperationsOwnFailureInTimeIsKept() async {
        await #expect(throws: Closed.self) {
            try await withAgentPaneDeadline(.seconds(600), label: "status") { () async throws -> Int in throw Closed() }
        }
    }
}
