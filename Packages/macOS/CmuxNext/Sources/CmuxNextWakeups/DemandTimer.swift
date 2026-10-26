import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:tolerance:_:)`` replaces a pending
/// deadline (reset); ``cancel()`` drops it. The clock is injected so tests do
/// not wait. Each fire records one wakeup in the ledger under `owner`.
///
/// Main-thread deadlines belong on ``MainWakeUpQueue`` (``AlignedWakeups``);
/// this timer stays for off-main deadlines. Every sleep passes a tolerance so
/// the OS can coalesce the wakeup with others: ``WakeLeeway``'s leeway for the
/// delay unless the caller asks for `.zero`.
public final class DemandTimer: Sendable {
    /// Who the deadline is for: each fire is one ledger record under it.
    public let owner: String
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let state = Mutex<State>(State())

    private struct State {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - owner: Who the deadline is for, in the wakeup ledger.
    ///   - clock: The clock the sleep runs on (tests inject their own).
    ///   - ledger: Where each fire is counted (`debug.wakeups`).
    public init(owner: String, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.owner = owner
        self.clock = clock
        self.ledger = ledger
    }

    deinit {
        state.withLock { $0.task?.cancel() }
    }

    /// True while a deadline is pending.
    public var isScheduled: Bool { state.withLock { $0.task != nil } }

    /// Runs `action` once after `delay`, replacing any pending deadline.
    ///
    /// - Parameters:
    ///   - delay: How long to wait.
    ///   - tolerance: How late the wakeup may be, passed to the clock's sleep. nil (the default) is
    ///     ``WakeLeeway/window(delay:policy:alignment:)``'s tolerance for `delay` (8 ms below 1 s,
    ///     10% up to 1 s from 1 s on); `.zero` asks for exact timing.
    ///   - action: Runs once at the deadline.
    public func schedule(after delay: Duration, tolerance: Duration? = nil,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        let tolerance = tolerance ?? WakeLeeway.window(delay: delay).tolerance
        state.withLock { state in
            state.task?.cancel()
            state.generation &+= 1
            let generation = state.generation
            state.task = Task { [weak self] in
                do { try await clock.sleep(for: delay, tolerance: tolerance) } catch { return }
                guard let self, self.take(generation) else { return }
                self.ledger.record(self.owner, reason: "deadline")
                await action()
            }
        }
    }

    /// Schedules only when nothing is pending (a deadline that is not pushed back).
    public func scheduleIfIdle(after delay: Duration, tolerance: Duration? = nil,
                               _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        guard !isScheduled else { return }
        schedule(after: delay, tolerance: tolerance, action)
    }

    /// Drops the pending deadline, if any; its action never runs.
    public func cancel() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.generation &+= 1
        }
    }

    /// Claims the fire for `generation`; false when it was reset or cancelled.
    private func take(_ generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, !Task.isCancelled else { return false }
            state.task = nil
            return true
        }
    }
}
