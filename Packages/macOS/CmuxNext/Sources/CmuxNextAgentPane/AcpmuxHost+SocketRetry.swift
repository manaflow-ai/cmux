import Foundation
import CmuxNextWakeups

extension AcpmuxHost {
    /// The spacing of a bounded retry while the daemon binds or recreates its Unix socket:
    /// 100, 200, 400, then 500 ms. No jitter: one app retries its own daemon, there is no herd.
    nonisolated static let socketRetryBackoff = Backoff(initial: .milliseconds(100), maximum: .milliseconds(500), jitter: 0)

    /// One wait of a bounded socket retry: the next Backoff step, cut to `remaining` (the time left
    /// before the caller's deadline), with Backoff's tolerance so the kernel may coalesce the wake.
    ///
    /// - Parameters:
    ///   - backoff: The retry's spacing; advanced one step.
    ///   - remaining: The time left before the retries end; the wait is never longer.
    ///   - clock: The clock the wait sleeps on; tests pass a `ManualClock`.
    ///   - ledger: Where the wait is recorded.
    nonisolated static func socketRetryWait(_ backoff: inout Backoff, remaining: Duration,
                                            clock: any Clock<Duration> = ContinuousClock(),
                                            ledger: WakeupLedger = .shared) async throws {
        let step = max(min(backoff.next(), remaining), .zero)
        // wakeup-allow: backoff a bounded socket retry; the caller's 3 s deadline ends the retries.
        try await clock.sleep(for: step, tolerance: Backoff.tolerance(for: step))
        ledger.record("agent-pane.daemon-socket", reason: "backoff")
    }
}
