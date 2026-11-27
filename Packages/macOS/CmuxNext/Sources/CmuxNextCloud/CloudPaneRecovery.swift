public import Foundation
import os

/// The chat pane start's recovery (Leo, goals/cloud-errors-self-recover: "Fix the cause"): a failed start first runs
/// what its card's Retry runs (the same send, the same key), as the one recovery table says (cmux-cloud-start-core
/// `recover::pane_step`, the table `cmux cloud start-chat` runs too), so the card shows only what a person must act
/// on, or what recovery could not fix.
public struct CloudPaneRecovery {
    public init() {}
    /// A failure the table may rerun: its code, words and whether the card would offer Retry.
    public struct Failure: Sendable, Equatable {
        public let code: String?, message: String, retryable: Bool
        public init(code: String?, message: String, retryable: Bool) { (self.code, self.message, self.retryable) = (code, message, retryable) }
    }

    /// A cap past the table's own (`PANE_RERUNS`), so the loop ends even if the FFI answered wrong.
    static let ceiling = 8
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// Runs `once` (one try, which sets its failure when the table may rerun it) until it answers with none, the
    /// table says show the card, or the task is cancelled; returns the last try's answer.
    public static func run<Answer>(core: CloudStartCore = CloudStartCore(), clock: ContinuousClock = ContinuousClock(),
                                   _ once: (inout Failure?) async -> Answer) async -> Answer {
        let began = clock.now
        var failed: Failure?
        var answer = await once(&failed)
        for reruns in 0 ..< ceiling {
            guard let failure = failed, !Task.isCancelled else { return answer }
            let elapsed = clock.now - began
            let elapsedMs = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            guard case .rerun(let ms, let cls) = core.paneRecovery(code: failure.code, message: failure.message, retryable: failure.retryable, reruns: reruns, elapsedMs: elapsedMs) else { return answer }
            logger.notice("cloud start chat recovering: rerun \(reruns + 1, privacy: .public) for \(cls ?? "start", privacy: .public) in \(ms, privacy: .public) ms")
            // wakeup-allow: bounded same-key rerun of a failed start (recover::pane_step: PANE_RERUNS within PANE_BUDGET)
            do { try await clock.sleep(for: .milliseconds(ms)) } catch { return answer }
            failed = nil
            answer = await once(&failed)
        }
        return answer
    }
}
