import CmuxNextWakeups
import Foundation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The work keeps running; its late result is dropped (the
/// first of the answer and the deadline resolves the ``FirstOutcome``).
@MainActor
enum CallDeadline {
    static func run(_ timeout: Duration?, what: String, _ body: @escaping @MainActor () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        let outcome = FirstOutcome<Result<DriverJSON, DriverError>>()
        let timer = DemandTimer(owner: "BrowserAutomation.callDeadline")
        timer.schedule(after: timeout) {
            outcome.resolve(.failure(DriverError(.timeout, "\(what): Timeout \(timeout) exceeded")))
        }
        // task-owner: ends when WebKit answers; the deadline above answers the caller first if needed.
        Task { @MainActor in
            let result: Result<DriverJSON, DriverError>
            do throws(DriverError) {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            timer.cancel()
            outcome.resolve(result)
        }
        return try await outcome.value().get()
    }
}
