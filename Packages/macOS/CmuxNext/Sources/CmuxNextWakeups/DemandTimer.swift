import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:_:)`` replaces a pending deadline
/// (reset); ``cancel()`` drops it. The clock is injected so tests do not
/// wait. Each fire records one wakeup in the ledger under `owner`.
/// ``settled()`` waits until the newest deadline has run out or was dropped.
public final class DemandTimer: Sendable {
    public let owner: String
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let state = Mutex<State>(State())

    private struct State {
        var generation: UInt64 = 0
        /// The newest deadline's task: asleep, claiming its fire, or running its action.
        /// It stays here after the fire, so ``settled()`` can wait for the action's end.
        var task: Task<Void, Never>?
        /// The newest deadline has not fired, been replaced or been cancelled yet.
        var pending = false
    }

    public init(owner: String, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.owner = owner
        self.clock = clock
        self.ledger = ledger
    }

    deinit {
        state.withLock { if $0.pending { $0.task?.cancel() } }
    }

    /// True while a deadline is pending.
    public var isScheduled: Bool { state.withLock { $0.pending } }

    /// Runs `action` once after `delay`, replacing any pending deadline.
    public func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        state.withLock { state in
            // A fire already claimed runs to its end; only a pending deadline is replaced.
            if state.pending { state.task?.cancel() }
            state.generation &+= 1
            state.pending = true
            let generation = state.generation
            state.task = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                guard let self, self.take(generation) else { return }
                self.ledger.record(self.owner, reason: "deadline")
                await action()
            }
        }
    }

    /// Schedules only when nothing is pending (a deadline that is not pushed back).
    public func scheduleIfIdle(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        guard !isScheduled else { return }
        schedule(after: delay, action)
    }

    public func cancel() {
        state.withLock { state in
            if state.pending { state.task?.cancel() }
            state.pending = false
            state.generation &+= 1
        }
    }

    /// Waits until the deadline that is newest now has settled: its action returned, or it was
    /// replaced or cancelled and its fire dropped. Returns at once when nothing was scheduled.
    ///
    /// A deadline still asleep keeps the wait going until its clock reaches it, so a test
    /// advances its clock first. Tests await this rather than a signal sent by the action: a
    /// deadline that is dropped ends the wait too, and the test's expectation reports it instead
    /// of the test hanging.
    public func settled() async {
        let task = state.withLock { $0.task }
        await task?.value
    }

    /// Claims the fire for `generation`; false when it was reset or cancelled.
    private func take(_ generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, !Task.isCancelled else { return false }
            state.pending = false
            return true
        }
    }
}
