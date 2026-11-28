import CmuxNextWakeups
import Foundation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The work keeps running; its late result is dropped.
@MainActor
enum CallDeadline {
    static func run(_ timeout: Duration?, what: String, _ body: @escaping @MainActor () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        let result: Result<DriverJSON, DriverError> = await withCheckedContinuation { continuation in
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
        return try result.get()
    }

    /// Resumes a continuation exactly once.
    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Result<DriverJSON, DriverError>, Never>?

        init(_ continuation: CheckedContinuation<Result<DriverJSON, DriverError>, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<DriverJSON, DriverError>) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}
