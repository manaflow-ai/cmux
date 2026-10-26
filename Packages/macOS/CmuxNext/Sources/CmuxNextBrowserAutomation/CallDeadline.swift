import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceContinuation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The work keeps running; its late result is dropped.
@MainActor
enum CallDeadline {
    static func run(_ timeout: Duration?, what: String, _ body: @escaping @MainActor () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        // Dropped unanswered (abandoned) is a closed call; the Task below holds the answer until it runs.
        return try await withOnceContinuation(failingWith: { _ in DriverError(.closed, "\(what): no answer") }) {
            (continuation: OnceContinuation<DriverJSON, DriverError>) in
            let once = Once(continuation)
            let timer = DemandTimer(owner: "BrowserAutomation.callDeadline")
            timer.schedule(after: timeout) {
                await once.resume(.failure(DriverError(.timeout, "\(what): Timeout \(timeout) exceeded")))
            }
            // task-owner: ends when WebKit answers; the deadline above answers the caller first if needed.
            Task { @MainActor in
                let outcome: Result<DriverJSON, DriverError>
                do throws(DriverError) {
                    outcome = .success(try await body())
                } catch {
                    outcome = .failure(error)
                }
                timer.cancel()
                once.resume(outcome)
            }
        }
    }

    /// Resumes a continuation exactly once: the deadline and the work legitimately race, so the loser is
    /// dropped here, not reported as a double resume.
    @MainActor
    private final class Once {
        private var continuation: OnceContinuation<DriverJSON, DriverError>?

        init(_ continuation: OnceContinuation<DriverJSON, DriverError>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<DriverJSON, DriverError>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
