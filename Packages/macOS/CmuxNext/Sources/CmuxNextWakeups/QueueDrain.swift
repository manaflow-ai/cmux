public import Dispatch
import CmuxNextCompat

/// Waits, holding no thread, until serial queues ran the work queued on them before the wait: the quit's
/// last state-file saves (the agent panes' drafts and scroll places, the paired phones' list), awaited on
/// the main actor under one limit. Chrome's shutdown never blocks the UI thread on a disk either.
///
/// One continuation for all the queues; the limit is a ``DemandTimer`` (cancelled once every queue
/// answered, so a quit with no backlog costs no timer fire). The clock is injected so tests do not wait.
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
        let countdown = QueueDrainCountdown(queues.count, deadline: DemandTimer(owner: "queue-drain", clock: clock))
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            countdown.start(done, within: limit)
            for queue in queues { queue.async { countdown.reached() } }
        }
    }
}

/// The queues one ``QueueDrain/drained(_:within:)`` still waits for, its continuation and its deadline.
private final class QueueDrainCountdown: Sendable {
    private let state: Mutex<(left: Int, done: CheckedContinuation<Bool, Never>?)>
    private let deadline: DemandTimer

    init(_ count: Int, deadline: DemandTimer) {
        state = Mutex((count, nil))
        self.deadline = deadline
    }

    func start(_ done: CheckedContinuation<Bool, Never>, within limit: Duration) {
        state.withLock { $0.done = done }
        deadline.schedule(after: limit) { [self] in finish(false) }
    }

    func reached() {
        let last = state.withLock { state -> Bool in
            state.left -= 1
            return state.left == 0
        }
        if last { finish(true) }
    }

    private func finish(_ drained: Bool) {
        let done = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            defer { state.done = nil }
            return state.done
        }
        guard let done else { return }
        deadline.cancel()
        done.resume(returning: drained)
    }
}
