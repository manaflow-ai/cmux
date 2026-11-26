import Foundation
import MessagesLabHome

/// The MessagesLab controller's engine-clock wake-ups: one pending one-shot
/// at a time, replaced by the next `schedule` and cancelled by `cancel`. No
/// polling and no display link. The controller calls it on the main thread.
final class ChiefWakeScheduler: ChatWakeScheduler {
    // task-owner: the one pending wake-up; replaced by the next schedule, cancelled by cancel()
    private var pending: Task<Void, Never>?

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        pending?.cancel()
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        // The delay is the wake-up itself (an engine deadline), not a poll; a replace or stop cancels it.
        pending = Task { @MainActor in
            if nanoseconds > 0 {
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
