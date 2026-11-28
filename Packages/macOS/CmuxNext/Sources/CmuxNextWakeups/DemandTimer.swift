import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:_:)`` replaces a pending deadline
/// (reset); ``cancel()`` drops it. The clock is injected so tests do not
/// wait. Each fire records one wakeup in the ledger under `owner`.
///
/// A timer made with an `early` window may run up to that much before its
/// deadline on a wake that already happened (``WakeCoalescer``): the ledger
/// then records it as `coalesced`, not as a wakeup of its own. Each deadline
/// that fires is such a wake for the others.
///
/// On the system clock the deadline is a dispatch timer, which a cancel takes
/// back: a cancelled `Task.sleep` that has begun still wakes the process at its
/// old deadline, so each reset, cancel and ride cost the wakeup it saved (40
/// cancelled sleeps made 24 wakeups, 40 cancelled dispatch timers none). An
/// injected clock (tests) sleeps in a `Task`.
public final class DemandTimer: Sendable {
    public let owner: String
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let early: Duration
    private let coalescer: WakeCoalescer
    private let coalescerID: UInt64
    private let state = Mutex<State>(State())

    private struct State {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
        var source: DispatchSourceTimer?

        var isPending: Bool { task != nil || source != nil }

        /// Drops the pending deadline's sleep or dispatch timer.
        mutating func stop() {
            task?.cancel()
            task = nil
            source?.cancel()
            source = nil
        }
    }

    /// The system clock's kind, when `clock` is one (a dispatch timer then holds the deadline).
    private enum SystemClock { case continuous, suspending }
    private let systemClock: SystemClock?

    /// - Parameter early: How long before its deadline the timer may run on another wake (zero: never).
    public init(owner: String, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                early: Duration = .zero, coalescer: WakeCoalescer? = nil) {
        self.owner = owner
        self.clock = clock
        self.ledger = ledger
        self.early = early
        systemClock = clock is ContinuousClock ? .continuous : clock is SuspendingClock ? .suspending : nil
        let coalescer = coalescer ?? ledger.coalescer
        self.coalescer = coalescer
        coalescerID = coalescer.makeID()
    }

    deinit {
        state.withLock { $0.stop() }
        coalescer.remove(coalescerID)
    }

    /// True while a deadline is pending.
    public var isScheduled: Bool { state.withLock { $0.isPending } }

    /// Runs `action` once after `delay`, replacing any pending deadline.
    public func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        schedule(after: delay, reason: "deadline", action)
    }

    /// ``schedule(after:_:)`` with the ledger's `reason` for its fire (what the deadline is for).
    public func schedule(after delay: Duration, reason: String,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        let systemClock = systemClock
        let generation = state.withLock { state in
            state.stop()
            state.generation &+= 1
            let generation = state.generation
            if let systemClock {
                // The handler only claims the fire and starts its action: a shared system queue, no thread of its own.
                let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                let nanos = Int(clamping: Self.nanoseconds(delay))
                switch systemClock {
                // Wall time goes on while the Mac sleeps, as ContinuousClock does; uptime does not.
                case .continuous:
                    source.schedule(wallDeadline: .now() + .nanoseconds(nanos), leeway: Self.leeway(nanos))
                case .suspending: source.schedule(deadline: .now() + .nanoseconds(nanos), leeway: Self.leeway(nanos))
                }
                source.setEventHandler { [weak self] in
                    guard let self, self.take(generation) else { return }
                    self.fired(reason: reason, action)
                }
                source.resume()
                state.source = source
            } else {
                state.task = Task { [weak self] in
                    do { try await clock.sleep(for: delay) } catch { return }
                    guard let self, self.take(generation) else { return }
                    self.recordFire(reason: reason)
                    await action()
                }
            }
            return generation
        }
        guard early > .zero, delay > early else {
            coalescer.remove(coalescerID)
            return
        }
        let opensAt = coalescer.nanoseconds &+ Self.nanoseconds(delay - early)
        coalescer.add(coalescerID, opensAt: opensAt) { [weak self] in
            guard let self, self.take(generation, cancelSleep: true) else { return }
            self.ledger.record(self.owner, reason: "coalesced")
            // task-owner: the action of a deadline that ran on another wake; ends when the action returns.
            Task(operation: action)
        }
    }

    /// The deadline fired (not a ride): it records its own wake, which the timers whose window is open share.
    private func recordFire(reason: String) {
        coalescer.remove(coalescerID)
        ledger.record(owner, reason: reason)
        coalescer.wake()
    }

    /// A dispatch timer's fire: records it, then starts the action.
    private func fired(reason: String, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        recordFire(reason: reason)
        // task-owner: the action of a deadline that fired; ends when the action returns.
        Task(operation: action)
    }

    /// A tenth of the delay, at most 100 ms, at least 1 ms: the kernel may join nearby deadlines into one wake.
    private static func leeway(_ nanos: Int) -> DispatchTimeInterval {
        .nanoseconds(min(max(nanos / 10, 1_000_000), 100_000_000))
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        return UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000).partialValue
            &+ UInt64(clamping: attoseconds / 1_000_000_000)
    }

    /// Schedules only when nothing is pending (a deadline that is not pushed back).
    public func scheduleIfIdle(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        guard !isScheduled else { return }
        schedule(after: delay, action)
    }

    public func cancel() {
        state.withLock { state in
            state.stop()
            state.generation &+= 1
        }
        coalescer.remove(coalescerID)
    }

    /// Claims the fire for `generation`; false when it was reset or cancelled. `cancelSleep`: the fire runs on
    /// another wake, so its own sleep ends now.
    private func take(_ generation: UInt64, cancelSleep: Bool = false) -> Bool {
        state.withLock { state in
            guard state.generation == generation, cancelSleep || !Task.isCancelled else { return false }
            if cancelSleep { state.task?.cancel() }
            state.task = nil
            // A fired dispatch timer is done; a ride's own deadline must not wake the process later.
            state.source?.cancel()
            state.source = nil
            // Claimed once: the deadline's own fire and a ride on another wake race for the same schedule.
            state.generation &+= 1
            return true
        }
    }
}
