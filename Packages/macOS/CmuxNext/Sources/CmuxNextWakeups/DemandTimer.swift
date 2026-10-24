import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:_:)`` replaces a pending deadline
/// (reset); ``cancel()`` drops it. The clock is injected so tests do not
/// wait. Each fire records one wakeup in the ledger under `owner`.
/// ``settled()`` waits until the newest deadline has run out or was dropped.
///
/// A fire is claimed on its action's own isolation (the actor the action is
/// isolated to, for example the main actor), in the same turn that runs the
/// action. So a ``schedule(after:_:)`` or ``cancel()`` that the actor makes
/// before that turn always wins, also when the deadline passed while the actor
/// was busy: the replaced action never runs and is not counted.
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
        let timer = WeakDemandTimer(self)
        state.withLock { state in
            // A fire already claimed runs to its end; only a pending deadline is replaced.
            if state.pending { state.task?.cancel() }
            state.generation &+= 1
            state.pending = true
            let generation = state.generation
            state.task = Task {
                do { try await clock.sleep(for: delay) } catch { return }
                await DemandTimer.fire(timer, generation: generation, action: action, isolation: action.isolation)
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

    /// Claims the fire for `generation` and runs `action`, both on `isolation`: the action's own
    /// actor (SE-0431), or the cooperative pool for a nonisolated action.
    ///
    /// Claiming on the pool and then hopping to the actor left a window: a `schedule` or `cancel`
    /// the actor made after the claim and before its turn could not stop the stale action. Here
    /// the claim and the action share one turn: calling `action` from its own isolation runs it
    /// inline, with no second hop, so nothing else runs on the actor between the two. `timer` is
    /// weak until then: a timer its owner dropped meanwhile was deinited, which dropped the fire.
    private static func fire(
        _ timer: WeakDemandTimer,
        generation: UInt64,
        action: @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)?
    ) async {
        guard let timer = timer.value, timer.take(generation) else { return }
        timer.ledger.record(timer.owner, reason: "deadline")
        await action()
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

/// A deadline task's weak reference to its timer, which it resolves only on the action's actor.
private struct WeakDemandTimer: Sendable {
    weak var value: DemandTimer?

    init(_ value: DemandTimer) { self.value = value }
}
