import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceContinuation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The work keeps running; its late result is dropped. The deadline sleeps on
/// `clock` (tests pass a `ManualClock`).
@MainActor
enum CallDeadline {
    static func run(_ timeout: Duration?, what: String, clock: any Clock<Duration> = ContinuousClock(),
                    _ body: @escaping @MainActor () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        let timedOut = DriverError(.timeout, "\(what): Timeout \(timeout) exceeded")
        return try await first(of: body, within: timeout, timedOut: timedOut, clock: clock).get()
    }

    /// The work's answer, or `timedOut` at the deadline. The deadline cancels the wait, which ends its
    /// cancellable continuation at once and makes the work's late answer a no-op (Chromium drops a late reply
    /// the same way: a `base::OnceCallback` bound to an invalidated `WeakPtr`). Off the main actor: only the
    /// work runs there, in its own isolation.
    private nonisolated static func first(of body: @escaping @MainActor () async throws(DriverError) -> DriverJSON,
                                          within timeout: Duration, timedOut: DriverError,
                                          clock: any Clock<Duration>) async -> Result<DriverJSON, DriverError> {
        // task-owner: the wait for the work's answer; ends with the answer or at the deadline below
        let wait = Task { () -> Result<DriverJSON, DriverError> in
            do throws(DriverError) {
                return .success(try await withOnceContinuation(cancellation: .cancellable, failingWith: { _ in timedOut }) {
                    (answer: OnceContinuation<DriverJSON, DriverError>) in
                    // task-owner: ends when WebKit answers; the deadline answers the caller first if needed.
                    Task {
                        do throws(DriverError) {
                            answer.resume(returning: try await body())
                        } catch {
                            answer.resume(throwing: error)
                        }
                    }
                })
            } catch {
                return .failure(error)
            }
        }
        let timer = DemandTimer(owner: "BrowserAutomation.callDeadline", clock: clock)
        timer.schedule(after: timeout) { wait.cancel() }
        let result = await wait.value
        timer.cancel()
        return result
    }
}
