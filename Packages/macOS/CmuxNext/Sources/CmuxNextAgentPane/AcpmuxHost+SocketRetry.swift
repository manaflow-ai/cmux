import Foundation
import CmuxNextWakeups

extension AcpmuxHost {
    /// The spacing of a bounded retry while the daemon binds or recreates its Unix socket:
    /// 100, 200, 400, then 500 ms. No jitter: one app retries its own daemon, there is no herd.
    nonisolated static let socketRetryBackoff = Backoff(initial: .milliseconds(100), maximum: .milliseconds(500), jitter: 0)

    /// One wait of a bounded socket retry: the next Backoff step, cut to the time left before
    /// `deadline`, with Backoff's tolerance so the kernel may coalesce the wake.
    nonisolated static func socketRetryWait(_ backoff: inout Backoff, until deadline: ContinuousClock.Instant,
                                            ledger: WakeupLedger = .shared) async throws {
        let step = min(backoff.next(), deadline - ContinuousClock.now)
        // wakeup-allow: backoff a bounded socket retry; the caller's 3 s deadline ends the retries.
        try await ContinuousClock().sleep(for: step, tolerance: Backoff.tolerance(for: step))
        ledger.record("agent-pane.daemon-socket", reason: "backoff")
    }
}
