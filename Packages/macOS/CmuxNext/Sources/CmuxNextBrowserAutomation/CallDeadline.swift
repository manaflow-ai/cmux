import CmuxNextWakeups
import Foundation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The work keeps running; its late result is dropped. The
/// deadline's rounding, cap and timeout text are Rust's (cmux-browser-rules
/// `driver.rs`, op `browser_rules_automation_call_deadline`).
@MainActor
enum CallDeadline {
    /// A deadline of `ms` milliseconds, rounded and capped, and the error a
    /// call named `what` answers when it passes first.
    nonisolated static func deadline(milliseconds ms: Double, what: String) -> (duration: Duration, message: String) {
        let reply = BrowserRulesFFI.call("call_deadline", ["what": what, "timeoutMs": ms.isFinite ? ms : 0])
        guard case .object(let fields)? = reply, let milliseconds = fields["milliseconds"]?.numberValue,
              let message = fields["message"]?.stringValue else {
            // The library always answers; only an app FFI pin behind the Rust lacks the op.
            return (.seconds(30), "\(what): Timeout exceeded")
        }
        return (.milliseconds(Int64(milliseconds)), message)
    }

    static func run(_ timeout: Duration?, what: String, _ body: @escaping @MainActor () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        let result: Result<DriverJSON, DriverError> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let timer = DemandTimer(owner: "BrowserAutomation.callDeadline")
            timer.schedule(after: timeout) {
                await once.resume(.failure(DriverError(.timeout, deadline(milliseconds: DriverParams.milliseconds(timeout), what: what).message)))
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
