import Foundation

/// Waits for another task to end, or for the caller to be cancelled, whichever comes first.
///
/// `await task.value` ignores the caller's cancellation: a send queued behind another (a chat
/// prompt behind an earlier one whose 4K video is still on its way) could not be stopped until
/// that earlier one finished (Leo, 2026-11-24: "i also couldnt cancel out of the send"). This
/// returns at once on Stop, and leaves `task` running: it belongs to whoever started it.
public enum CancellableWait {
    /// Returns when `task` has ended; throws `CancellationError` the moment the caller is
    /// cancelled (at once if it already was).
    public static func until<Success: Sendable>(_ task: Task<Success, Never>) async throws {
        try Task.checkCancellation()
        let gate = Gate()
        let watcher = Task {
            _ = await task.value
            gate.open(cancelled: false)
        }
        defer { watcher.cancel() }
        let cancelled = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in gate.wait(continuation) }
        } onCancel: {
            gate.open(cancelled: true)
        }
        if cancelled { throw CancellationError() }
    }

    /// Resumes its one waiter once, with whichever of "ended" or "cancelled" came first; an
    /// opening before the waiter arrives is kept for it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        func wait(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiter = continuation
            lock.unlock()
        }

        func open(cancelled: Bool) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = cancelled
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: cancelled)
        }
    }
}
