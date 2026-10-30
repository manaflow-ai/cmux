public import Dispatch
import CmuxNextCompat

/// Waits, holding no thread, until serial queues ran the work queued on them before the wait: the quit's
/// last state-file saves (the agent panes' drafts and scroll places, the paired phones' list), awaited on
/// the main actor under one limit. Chrome's shutdown never blocks the UI thread on a disk either.
///
/// A ``FirstOutcome`` races the last queue's answer against a one-shot ``DemandTimer`` limit (cancelled
/// once every queue answered, so a quit with no backlog costs no timer fire). The clock is injected so
/// tests do not wait.
public final class QueueDrain: Sendable {
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// True once each of `queues` reached the point of this call, false when `limit` passed first.
    ///
    /// - Parameters:
    ///   - queues: The serial queues to wait for.
    ///   - limit: How long to wait at most, for all the queues together.
    /// - Returns: Whether every queue was reached in time.
    @discardableResult
    public func drained(_ queues: [DispatchQueue], within limit: Duration) async -> Bool {
        guard !queues.isEmpty else { return true }
        let outcome = FirstOutcome<Bool>()
        let left = QueueDrainCount(queues.count)
        let deadline = DemandTimer(owner: "queue-drain", clock: clock)
        deadline.schedule(after: limit) { outcome.resolve(false) }
        for queue in queues {
            queue.async { if left.reachedLast() { outcome.resolve(true) } }
        }
        let drained = await outcome.value()
        deadline.cancel()
        return drained
    }
}

/// The queues one ``QueueDrain/drained(_:within:)`` still waits for.
private final class QueueDrainCount: Sendable {
    private let left: Mutex<Int>

    init(_ count: Int) {
        left = Mutex(count)
    }

    /// Counts one queue's answer; true for the last one.
    func reachedLast() -> Bool {
        left.withLock { left in
            left -= 1
            return left == 0
        }
    }
}
