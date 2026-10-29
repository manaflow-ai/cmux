import Foundation
import CmuxNextCompat

/// A one-shot deadline: debounce, timeout, delayed show/hide. The only timer
/// CmuxNext may use outside animation frames (plans/cmux-next/idle-wakeups.md).
///
/// It never repeats. ``schedule(after:tolerance:_:)`` replaces a pending
/// deadline (reset); ``cancel()`` drops it. A synchronous main-actor action
/// uses ``scheduleOnMain(after:tolerance:_:)`` and
/// ``scheduleOnMainIfIdle(after:tolerance:_:)``. The clock is injected so tests
/// do not wait. Each fire records one wakeup in the ledger under `owner`.
///
/// A timer given the app's ``MainWakeUpQueue`` (``init(owner:policy:clock:ledger:mainWork:)``)
/// puts main-actor deadlines on it, so they share the main thread's one run-loop timer and wake no
/// pool thread (Chromium posts a delayed task to the thread's own sequence, whose `WakeUpQueue`
/// arms the pump's one `delayed_work_timer_`, base/message_loop/message_pump_apple.mm). The action's
/// `@isolated(any)` isolation decides: a `@MainActor` action is a queue entry whose fire starts one
/// `Task` on the main actor (the thread is already awake); ``scheduleOnMain(after:tolerance:_:)``
/// runs a synchronous main-actor action inline in the fire, with no `Task`. Any other action, and
/// every action of a timer with no queue, sleeps on the clock.
///
/// The two paths have two clocks. A queue entry's deadline is the queue's uptime (`CLOCK_UPTIME_RAW`,
/// which stops while the Mac sleeps, as Chromium's `TimeTicks` on macOS does) plus the delay, and it
/// fires from the queue's timer; the injected `clock` never sees it. A test of a main-actor action
/// fires the queue (`WakeUpQueueRig`), not a `ManualClock`. Every sleep passes a tolerance so
/// the OS can coalesce the wakeup with others: the ``WakeLeeway`` window of the
/// timer's ``DelayPolicy`` for the delay (Chromium's `PostDelayedTask` with a
/// `subtle::DelayPolicy`, base/task/delay_policy.h). A `.precise` timer below
/// 36 ms asks for no tolerance; a 5 s flexible one asks 0.5 s. The sub-second
/// leeway is the injected ``EnergyPolicySource``'s wake alignment (32 ms under
/// Energy Saver), read at each schedule; an owner with no source gets 8 ms. A
/// caller's explicit tolerance replaces the leeway, never the policy.
///
/// In Debug and bench builds each timer also tells its ledger's ``ArmCensus`` (startup-queue.py arms)
/// when it is armed during the launch and when it first fires, under the owner and the line that made it.
public final class DemandTimer: Sendable {
    /// Who the deadline is for: each fire is one ledger record under it.
    public let owner: String
    /// How strictly each deadline is honored; `.flexibleNoSooner` by default.
    public let policy: DelayPolicy
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    /// The app's Energy Saver policy (`MainWorkScheduler.energy`); nil keeps the 8 ms default.
    private let energy: EnergyPolicySource?
    /// The main thread's deadline queue (`MainWorkScheduler.wakeUps`); nil sleeps every deadline.
    private let wakeUps: MainWakeUpQueue?
    /// What the queue records for a fire of this timer's entries (``MainWakeUpQueue/LedgerReason``).
    private let queueLedgerReason: MainWakeUpQueue.LedgerReason
    private let state = Mutex<State>(State())
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The line that made the timer, for the arm census.
    private let site: ArmCensus.Site
    #endif

    /// The one pending deadline: a task asleep on the clock, or an entry in the main queue.
    private enum Pending {
        case sleeping(Task<Void, Never>)
        case queued(MainWakeUpQueue.Token)
    }

    /// The timer's lock is taken before the queue's (a reset inserts the new entry under it) and never
    /// inside it: the queue runs an entry with its own lock released. A dropped deadline is cancelled
    /// after both locks are released (``drop(_:)``), because dropping a queue entry frees its action.
    private struct State {
        var generation: UInt64 = 0
        var pending: Pending?
        #if DEBUG || CMUX_BENCH_HOOKS
        var census = ArmCensusEntry()
        #endif

        /// Starts a new generation, so a fire of the old deadline is a no-op, and takes the old
        /// deadline out for ``DemandTimer/drop(_:)``.
        mutating func supersede() -> Pending? {
            generation &+= 1
            defer { pending = nil }
            return pending
        }
    }

    /// - Parameters:
    ///   - owner: The ledger name of each fire.
    ///   - policy: How strictly each deadline is honored (``DelayPolicy``).
    ///   - clock: The clock the timer sleeps on; tests pass a `ManualClock`. It times only the sleep
    ///     path: a main-actor action on `wakeUps` runs on the queue's uptime instead.
    ///   - ledger: Where each fire is recorded.
    ///   - energy: The app's Energy Saver policy, which sets the sub-second wake alignment.
    ///     Owners with a `MainWorkScheduler` pass `mainWork.energy`; nil keeps 8 ms.
    ///   - wakeUps: The main thread's deadline queue, where main-actor actions go. Owners with a
    ///     `MainWorkScheduler` pass `mainWork.wakeUps`; nil sleeps every deadline on `clock`. Its
    ///     deadlines are uptime, which does not count system sleep: a deadline that must (an expiry
    ///     measured in wall time) uses a nonisolated action, which sleeps on `clock`.
    ///   - queueLedgerReason: What a fire of a queue entry records for `owner`: `deadline` (the default), or
    ///     `deadline` only for a wake that ran no other entry (``MainWakeUpQueue/LedgerReason/deadlineWhenAlone``).
    ///     A sleep always records `deadline`: it wakes a pool thread of its own.
    ///   - file: The line that made the timer, named by the arm census in Debug and bench builds (leave the default).
    ///   - line: See `file`.
    public init(owner: String, policy: DelayPolicy = .flexibleNoSooner, clock: any Clock<Duration> = ContinuousClock(),
                ledger: WakeupLedger = .shared, energy: EnergyPolicySource? = nil, wakeUps: MainWakeUpQueue? = nil,
                queueLedgerReason: MainWakeUpQueue.LedgerReason = .deadline,
                file: StaticString = #fileID, line: UInt = #line) {
        self.owner = owner
        self.policy = policy
        self.clock = clock
        self.ledger = ledger
        self.energy = energy
        self.wakeUps = wakeUps
        self.queueLedgerReason = queueLedgerReason
        #if DEBUG || CMUX_BENCH_HOOKS
        site = ArmCensus.Site(file: file, line: line)
        #endif
    }

    /// A timer on the app's scheduler: its Energy Saver policy and its main-thread deadline queue. Its
    /// main-actor actions run on the queue's uptime and the rest sleep on `ContinuousClock`; it takes no
    /// `clock`, since a `ManualClock` would time only the second kind. A test that needs both seams
    /// passes `clock:` and `wakeUps:` to the designated init.
    public convenience init(owner: String, policy: DelayPolicy = .flexibleNoSooner, ledger: WakeupLedger = .shared,
                            mainWork: MainWorkScheduler, file: StaticString = #fileID, line: UInt = #line) {
        self.init(owner: owner, policy: policy, ledger: ledger, energy: mainWork.energy, wakeUps: mainWork.wakeUps,
                  file: file, line: line)
    }

    deinit {
        drop(state.withLock { $0.supersede() })
    }

    /// True while a deadline is pending.
    public var isScheduled: Bool { state.withLock { $0.pending != nil } }

    /// Runs `action` once after `delay`, replacing any pending deadline.
    ///
    /// - Parameters:
    ///   - delay: How long to wait.
    ///   - tolerance: The leeway of this deadline, in place of the ``WakeLeeway`` default (0 when
    ///     precise below 36 ms, the wake alignment below 1 s, 10% up to 1 s from 1 s on). ``policy``
    ///     still decides its side: after the deadline for `.flexibleNoSooner`, before it for
    ///     `.flexiblePreferEarly`, and none for `.precise` below 36 ms. `.zero` asks for exact timing.
    ///   - action: Runs once at the deadline. A `@MainActor` action on a timer with a queue starts
    ///     from the queue's fire in one `Task` on the main actor; any other sleeps on the clock.
    public func schedule(after delay: Duration, tolerance: Duration? = nil,
                         _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        if let wakeUps, let isolation = action.isolation, isolation === MainActor.shared {
            enqueue(on: wakeUps, after: delay, tolerance: tolerance) { _ = Task<Void, Never>(operation: action) }
        } else {
            sleepThenRun(after: delay, tolerance: tolerance, action)
        }
    }

    /// ``schedule(after:tolerance:_:)`` for a synchronous main-actor action: on a timer with a queue it
    /// runs inline in the queue's fire, with no `Task` and no pool thread. A timer with no queue sleeps
    /// on the clock and runs it on the main actor. A separate name, not an overload of `schedule`: a
    /// trailing closure with no `await` would match both, and one written off the main actor would
    /// silently become main-actor work.
    public func scheduleOnMain(after delay: Duration, tolerance: Duration? = nil,
                               _ action: @escaping @MainActor @Sendable () -> Void) {
        if let wakeUps {
            enqueue(on: wakeUps, after: delay, tolerance: tolerance, action)
        } else {
            sleepThenRun(after: delay, tolerance: tolerance) { @MainActor in action() }
        }
    }

    /// Schedules only when nothing is pending (a deadline that is not pushed back).
    public func scheduleIfIdle(after delay: Duration, tolerance: Duration? = nil,
                               _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        guard !isScheduled else { return }
        schedule(after: delay, tolerance: tolerance, action)
    }

    /// ``scheduleIfIdle(after:tolerance:_:)`` for a synchronous main-actor action: schedules
    /// ``scheduleOnMain(after:tolerance:_:)`` only when nothing is pending.
    public func scheduleOnMainIfIdle(after delay: Duration, tolerance: Duration? = nil,
                                     _ action: @escaping @MainActor @Sendable () -> Void) {
        guard !isScheduled else { return }
        scheduleOnMain(after: delay, tolerance: tolerance, action)
    }

    /// Drops the pending deadline, if any; its action never runs.
    public func cancel() {
        drop(state.withLock { $0.supersede() })
    }

    /// Replaces the pending deadline with a task asleep on the clock; its fire records `deadline`.
    private func sleepThenRun(after delay: Duration, tolerance: Duration?,
                              _ action: @escaping @isolated(any) @Sendable () async -> Void) {
        let clock = clock
        let request = sleepRequest(for: delay, tolerance: tolerance)
        let dropped = state.withLock { state -> Pending? in
            let old = state.supersede()
            noteArm(&state)
            let generation = state.generation
            state.pending = .sleeping(Task { @concurrent [weak self] in
                // timer-class-allow: DemandTimer's own sleep, the off-main deadline recipe R-timer keeps; main-actor actions go through the wake-up queue when the timer has one
                do { try await clock.sleep(for: request.delay, tolerance: request.tolerance) } catch { return }
                guard let self, self.take(generation) else { return }
                self.ledger.record(self.owner, reason: "deadline")
                await action()
            })
            return old
        }
        drop(dropped)
    }

    /// Replaces the pending deadline with an entry in `queue`, which records its wake and this owner's
    /// `deadline` (as ``queueLedgerReason`` says). `action` runs only while the entry holds the timer's
    /// generation, so a reset or cancel that lands after the queue popped the entry still wins.
    private func enqueue(on queue: MainWakeUpQueue, after delay: Duration, tolerance: Duration?,
                         _ action: @escaping @MainActor @Sendable () -> Void) {
        let (sum, overflow) = queue.now.addingReportingOverflow(delay.nanosecondCount)
        let deadline = overflow ? UInt64.max : sum
        let window = mainWindow(for: delay, tolerance: tolerance, alignment: queue.alignment)
        let owner = owner, reason = queueLedgerReason
        let dropped = state.withLock { state -> Pending? in
            let old = state.supersede()
            noteArm(&state)
            let generation = state.generation
            let token = queue.insert(owner: owner, at: deadline, window: window, ledgerReason: reason) { [weak self] in
                guard let self, self.take(generation) else { return }
                self.fire(action)
            }
            state.pending = .queued(token)
            return old
        }
        drop(dropped)
    }

    /// Runs a main-actor deadline's action. In a launch the main-job census armed (Debug and bench builds)
    /// the fire is timed as a `timer` job named by ``owner``, since its stack shows only the queue.
    @MainActor private func fire(_ action: @MainActor () -> Void) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let ring = MainJobRing.installed(),
           let slot = ring.recordEnqueue(.timer, priority: MainJobRing.currentPriority, label: owner) {
            return ring.run(slot: slot) { action() }
        }
        #endif
        action()
    }

    /// Cancels a superseded sleep or drops a superseded queue entry. Called with no lock held: dropping an
    /// entry frees its action, and what the action held may deinit an owner that cancels this timer or
    /// another one on the same queue. Its generation is already stale, so a fire that wins the race does
    /// nothing.
    private func drop(_ pending: Pending?) {
        switch pending {
        case .sleeping(let task): task.cancel()
        case .queued(let token): wakeUps?.cancel(token)
        case nil: break
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

    /// The queue window of a main-actor deadline: ``policy``'s ``WakeLeeway`` window on the queue's
    /// alignment, with the caller's tolerance as its leeway when given (the rule of
    /// ``sleepRequest(for:tolerance:)``: an effective `.precise` deadline stays exact).
    private func mainWindow(for delay: Duration, tolerance: Duration?, alignment: Duration) -> WakeLeeway {
        let window = WakeLeeway.window(delay: delay, policy: policy, alignment: alignment)
        guard let tolerance, window.policy != .precise else { return window }
        return WakeLeeway(delay: delay, policy: window.policy, leeway: max(tolerance, .zero), grid: window.grid)
    }

    /// Claims the fire for `generation`; false when it was reset or cancelled.
    private func take(_ generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, !Task.isCancelled else { return false }
            state.pending = nil
            #if DEBUG || CMUX_BENCH_HOOKS
            state.census.fired(in: ledger.armCensus)
            #endif
            return true
        }
    }

    /// Tells the arm census about a new deadline (Debug and bench builds; nothing in Release). Called under the
    /// timer's lock: the census's lock is a leaf.
    @inline(__always)
    private func noteArm(_ state: inout State) {
        #if DEBUG || CMUX_BENCH_HOOKS
        state.census.armed(in: ledger.armCensus, .timer, owner: owner, site: site)
        #endif
    }
}
