#if DEBUG
import AppKit

/// Waits for the production monitor's callback, with a bounded capture deadline.
@MainActor
final class ShortcutHintCaptureWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?

    func wait(post: () -> Void) async -> Bool {
        guard continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            deadline = Task { [weak self] in
                // wakeup-allow: bounded DEBUG capture deadline, cancelled on the monitor callback; never polling.
                do { try await ContinuousClock().sleep(for: .seconds(2)) } catch { return }
                self?.finish(false)
            }
            post()
        }
    }

    func finish(_ shown: Bool) {
        let waiting = continuation
        continuation = nil
        deadline?.cancel()
        deadline = nil
        waiting?.resume(returning: shown)
    }
}
#endif
