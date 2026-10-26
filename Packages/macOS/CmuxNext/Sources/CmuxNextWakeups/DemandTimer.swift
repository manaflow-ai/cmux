import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:tolerance:_:)`` replaces a pending
/// deadline (reset); ``cancel()`` drops it. The clock is injected so tests do
/// not wait. Each fire records one wakeup in the ledger under `owner`.
///
/// Main-thread deadlines use ``AlignedWakeups`` (on ``MainWakeUpQueue``);
/// this timer stays for off-main deadlines, and a deadline that may be late
/// passes a `tolerance` so the OS can coalesce its wakeup with others.
public final class DemandTimer: Sendable {
    public let owner: String
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let state = Mutex<State>(State())

    private struct State {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
    }

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
    ///   - tolerance: How late the wakeup may be, passed to the clock's sleep (nil: the clock's default).
    ///     ``WakeLeeway/window(delay:policy:alignment:)``'s `tolerance` is the usual value.
    ///   - action: Runs once at the deadline.
    public func schedule(after delay: Duration, tolerance: Duration? = nil,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
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
