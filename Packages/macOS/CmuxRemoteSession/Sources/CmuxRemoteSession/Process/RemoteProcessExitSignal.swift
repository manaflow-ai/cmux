internal import CmuxFoundation
internal import Foundation

/// One-shot process-exit notification with deadline-aware blocking waits.
///
/// Foundation can report `isRunning == false` just before its termination
/// callback runs. `recordExit()` is therefore idempotent so the blocking owner
/// may publish that observed exit without racing the callback.
final class RemoteProcessExitSignal: Sendable {
    private let didExit = AtomicBooleanGate(false)
    private let group = DispatchGroup()

    init() {
        group.enter()
    }

    func recordExit() {
        guard didExit.compareExchange(expected: false, desired: true) else {
            return
        }
        group.leave()
    }

    func wait(until deadline: DispatchTime) -> Bool {
        group.wait(timeout: deadline) == .success
    }
}
