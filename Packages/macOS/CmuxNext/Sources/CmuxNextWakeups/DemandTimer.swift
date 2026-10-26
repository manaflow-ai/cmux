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
/// the OS can coalesce the wakeup with others: the ``WakeLeeway`` window of the
/// timer's ``DelayPolicy`` for the delay (Chromium's `PostDelayedTask` with a
/// `subtle::DelayPolicy`, base/task/delay_policy.h). A `.precise` timer below
/// 36 ms asks for no tolerance; a 5 s flexible one asks 0.5 s. The sub-second
/// leeway is the injected ``EnergyPolicySource``'s wake alignment (32 ms under
/// Energy Saver), read at each schedule; an owner with no source gets 8 ms. A
/// caller's explicit tolerance replaces the leeway, never the policy.
public final class DemandTimer: Sendable {
    public let owner: String
    /// How strictly each deadline is honored; `.flexibleNoSooner` by default.
    public let policy: DelayPolicy
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    /// The app's Energy Saver policy (`MainWorkScheduler.energy`); nil keeps the 8 ms default.
    private let energy: EnergyPolicySource?
    private let state = Mutex<State>(State())

    private struct State {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - owner: The ledger name of each fire.
    ///   - policy: How strictly each deadline is honored (``DelayPolicy``).
    ///   - clock: The clock the timer sleeps on; tests pass a `ManualClock`.
    ///   - ledger: Where each fire is recorded.
    ///   - energy: The app's Energy Saver policy, which sets the sub-second wake alignment.
    ///     Owners with a `MainWorkScheduler` pass `mainWork.energy`; nil keeps 8 ms.
    public init(owner: String, policy: DelayPolicy = .flexibleNoSooner, clock: any Clock<Duration> = ContinuousClock(),
                ledger: WakeupLedger = .shared, energy: EnergyPolicySource? = nil) {
        self.owner = owner
        self.policy = policy
        self.clock = clock
        self.ledger = ledger
        self.energy = energy
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
    ///   - tolerance: The leeway of this deadline, in place of the ``WakeLeeway`` default (0 when
    ///     precise below 36 ms, the wake alignment below 1 s, 10% up to 1 s from 1 s on). ``policy``
    ///     still decides its side: after the deadline for `.flexibleNoSooner`, before it for
    ///     `.flexiblePreferEarly`, and none for `.precise` below 36 ms. `.zero` asks for exact timing.
    ///   - action: Runs once at the deadline.
    public func schedule(after delay: Duration, tolerance: Duration? = nil,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        let request = sleepRequest(for: delay, tolerance: tolerance)
        state.withLock { state in
            state.task?.cancel()
            state.generation &+= 1
            let generation = state.generation
            state.task = Task { [weak self] in
                do { try await clock.sleep(for: request.delay, tolerance: request.tolerance) } catch { return }
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

    /// The relative sleep and tolerance for a deadline `delay` from now: ``policy``'s ``WakeLeeway``
    /// window on the energy source's wake alignment, with the caller's tolerance as its leeway when
    /// given. As in Chromium, the policy always decides where the leeway lies
    /// (base/task/delay_policy.h): `.flexiblePreferEarly` sleeps its leeway short, since a clock sleep
    /// only fires late, and an effective `.precise` deadline gets no leeway.
    private func sleepRequest(for delay: Duration, tolerance: Duration?) -> (delay: Duration, tolerance: Duration) {
        let alignment = energy?.policy.wakeAlignment ?? WakeLeeway.defaultAlignment
        let window = WakeLeeway.window(delay: delay, policy: policy, alignment: alignment)
        guard let tolerance else { return (window.sleepDelay, window.tolerance) }
        let leeway = max(tolerance, .zero)
        switch window.policy {
        case .precise: return (delay, .zero)
        case .flexibleNoSooner: return (delay, leeway)
        case .flexiblePreferEarly: return (max(delay - leeway, .zero), leeway)
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
