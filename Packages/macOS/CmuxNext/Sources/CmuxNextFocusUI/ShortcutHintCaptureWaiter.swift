#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Waits for the production monitor's callback, with a bounded capture deadline.
@MainActor
public final class ShortcutHintCaptureWaiter {
    private var continuation: OnceContinuation<Bool, OnceContinuationError>?
    private var deadline: Task<Void, Never>?

    public init() {}

    public func wait(post: () -> Void) async -> Bool {
        guard continuation == nil else { return false }
        // A dropped wait reads as not shown, as the deadline answers.
        return (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            self.continuation = continuation
            // main-hop-allow: debug capture wait: the Task only ends the wait at its deadline
            deadline = Task { [weak self] in
                let limit = Duration.seconds(2)
                // wakeup-allow: debug capture deadline, cancelled on the monitor callback; never polling;
                // not a DemandTimer: main actor (timer-class asks MainDeadline, and this type has no MainDeadlineScheduler seam)
                // timer-class-allow: debug capture deadline, cancelled by the monitor's callback; this type has no deadline-scheduler seam
                do { try await ContinuousClock().sleep(for: limit, tolerance: WakeLeeway.window(delay: limit).tolerance) } catch { return }
                self?.finish(false)
            }
            post()
        }) ?? false
    }

    public func finish(_ shown: Bool) {
        let waiting = continuation
        continuation = nil
        deadline?.cancel()
        deadline = nil
        waiting?.resume(returning: shown)
    }
}
#endif
