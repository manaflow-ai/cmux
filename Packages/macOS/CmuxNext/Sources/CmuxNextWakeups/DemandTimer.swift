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
    }

    /// - Parameter early: How long before its deadline the timer may run on another wake (zero: never).
    public init(owner: String, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                early: Duration = .zero, coalescer: WakeCoalescer? = nil) {
        self.owner = owner
        self.clock = clock
        self.ledger = ledger
        self.early = early
        let coalescer = coalescer ?? ledger.coalescer
        self.coalescer = coalescer
        coalescerID = coalescer.makeID()
    }

    deinit {
        state.withLock { $0.task?.cancel() }
        coalescer.remove(coalescerID)
    }

    /// True while a deadline is pending.
    public var isScheduled: Bool { state.withLock { $0.task != nil } }

    /// Runs `action` once after `delay`, replacing any pending deadline.
    public func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        schedule(after: delay, reason: "deadline", action)
    }

    /// ``schedule(after:_:)`` with the ledger's `reason` for its fire (what the deadline is for).
    public func schedule(after delay: Duration, reason: String,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        let generation = state.withLock { state in
            state.task?.cancel()
            state.generation &+= 1
            let generation = state.generation
            state.task = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                guard let self, self.take(generation) else { return }
                self.coalescer.remove(self.coalescerID)
                self.ledger.record(self.owner, reason: reason)
                // This deadline woke the app: the timers whose window is open run on the same wake.
                self.coalescer.wake()
                await action()
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
            state.task?.cancel()
            state.task = nil
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
            // Claimed once: the deadline's own fire and a ride on another wake race for the same schedule.
            state.generation &+= 1
            return true
        }
    }
}
