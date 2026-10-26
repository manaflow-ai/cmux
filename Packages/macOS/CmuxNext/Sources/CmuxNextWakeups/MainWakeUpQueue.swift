import CmuxNextCompat
import CoreFoundation
import Foundation

/// Every main-thread deadline on one timer, so deadlines that are close share one wake.
///
/// Chromium's model for a thread's delayed work, on the main run loop:
/// - One `CFRunLoopTimer` in common modes, created once and re-armed with
///   `CFRunLoopTimerSetNextFireDate`, never re-created (`MessagePumpCFRunLoopBase::delayed_work_timer_`,
///   base/message_loop/message_pump_apple.mm). A re-arm to the armed date is skipped
///   (`delayed_work_scheduled_at_`), and the tolerance is set before the date ("or it may be ignored").
/// - One heap of every pending deadline, ordered by latest time (`WakeUpQueue`,
///   base/task/sequence_manager/wake_up_queue.h): ``MainWakeUpHeap``.
/// - Fire dates snapped up to a grid of `CLOCK_UPTIME_RAW` nanoseconds and clamped to the latest time
///   (`MessagePump::AdjustDelayedRunTime` under `kAlignWakeUps`, base/message_loop/message_pump.cc);
///   precise entries are never snapped. The grid and leeway of each entry are ``WakeLeeway``'s.
/// - The sub-second grid and leeway are the injected ``EnergyPolicySource``'s `wakeAlignment`: 8 ms,
///   32 ms under Energy Saver (`SetBatterySaverMode` -> `MessagePump::OverrideAlignWakeUpsState(true, 32 ms)`,
///   content/child/child_thread_impl.cc). As in Chrome, an entry's leeway is fixed when it is inserted
///   (`PendingTask::latest_delayed_run_time`, base/pending_task.cc) and the grid is applied at wake time
///   (`AdjustDelayedRunTime`): a switch snaps every pending flexible sub-second entry to the new grid,
///   never past the latest time it was inserted with. Precise and whole-second entries keep theirs.
///
/// ``insert(owner:after:policy:_:)`` and ``cancel(_:)`` work from any thread. They re-arm the timer only
/// when the fire date changes, earlier or later (`ScheduleDelayedWorkImpl` skips only an equal date); an
/// insert behind the top costs nothing. A fire runs every due entry on the main actor in deadline order,
/// with one ledger record per owner that ran (reason `deadline`) and one `MainWakeUpQueue` `fire` record
/// per wake. No Task and no pool thread take part.
public final class MainWakeUpQueue: Sendable {
    /// Names one pending entry for ``cancel(_:)``.
    public struct Token: Hashable, Sendable {
        let id: UInt64
    }

    /// The work of one entry. It runs on the main thread, from a run-loop block the timer's callout queues.
    public typealias Action = @MainActor @Sendable () -> Void

    /// The `WakeupLedger` owner of the queue's own wakes (reason `fire`).
    public static let ledgerOwner = "MainWakeUpQueue"

    private struct State {
        var heap = MainWakeUpHeap<Action>()
        var nextID: UInt64 = 0
        /// The uptime the timer is armed for and the last instant its tolerance lets it fire; nil while
        /// it is parked.
        var armed: (date: UInt64, end: UInt64)?
        var timer: (any MainWakeUpTimer)?
        /// The sub-second leeway of new entries (the energy policy's `wakeAlignment`; the heap holds the grid).
        var alignment: Duration
        var energyObservation: EnergyPolicyObservation?
    }

    /// The timer is armed with the lock held, so two inserts on different threads can not arm in the
    /// opposite order of their dates (a late arm would delay the earlier deadline). CFRunLoop calls a
    /// timer out with none of its own locks held, and the energy source's lock is a leaf (``realign()``
    /// reads it inside this one; the source calls observers outside its lock), so locks are always taken
    /// in the same order.
    private let state: Mutex<State>
    private let energy: EnergyPolicySource
    private let ledger: WakeupLedger
    private let uptime: @Sendable () -> UInt64

    /// Makes the queue and its one main run-loop timer, parked until the first insert.
    ///
    /// - Parameters:
    ///   - energy: The policy whose `wakeAlignment` is the sub-second grid and leeway of flexible entries
    ///     (``WakeLeeway/defaultAlignment``; ``WakeLeeway/saverAlignment`` under Energy Saver): the
    ///     composition root's one source. It has no default, so no queue misses the saver silently.
    ///   - ledger: Where each fire and each owner that runs in it are counted (`debug.wakeups`).
    ///   - uptime: Monotonic nanoseconds, `CLOCK_UPTIME_RAW` (tests inject a fake).
    public convenience init(
        energy: EnergyPolicySource,
        ledger: WakeupLedger = .shared,
        uptime: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime
    ) {
        self.init(energy: energy, ledger: ledger, uptime: uptime, makeTimer: { MainRunLoopWakeUpTimer(fire: $0) })
    }

    /// The seam initializer: `makeTimer` gets the queue's fire callout and returns the timer it drives.
    /// The timer is made inside the lock: a `@Sendable` factory called with a `Sendable` callout returns
    /// a value no other code holds, so it can move into the `Mutex` without being `Sendable` itself.
    init(
        energy: EnergyPolicySource,
        ledger: WakeupLedger,
        uptime: @escaping @Sendable () -> UInt64,
        makeTimer: @Sendable (@escaping Action) -> any MainWakeUpTimer
    ) {
        state = Mutex(State(alignment: WakeLeeway.defaultAlignment))
        self.energy = energy
        self.ledger = ledger
        self.uptime = uptime
        let fire: Action = { [weak self] in self?.fire() }
        state.withLock { $0.timer = makeTimer(fire) }
        let observation = energy.observe { [weak self] _ in self?.realign() }
        state.withLock { $0.energyObservation = observation }
        realign()
    }

    /// Entries waiting to run.
    public var count: Int { state.withLock { $0.heap.count } }

    /// Runs `action` on the main thread `delay` from now, in the window ``WakeLeeway`` gives `delay` and
    /// `policy` at the energy policy's alignment. Callable from any thread.
    @discardableResult
    public func insert(
        owner: String, after delay: Duration, policy: DelayPolicy = .flexibleNoSooner, _ action: @escaping Action
    ) -> Token {
        let (sum, overflow) = uptime().addingReportingOverflow(delay.nanosecondCount)
        let deadline = overflow ? .max : sum
        return state.withLock { state in
            let window = WakeLeeway.window(delay: delay, policy: policy, alignment: state.alignment)
            return add(&state, owner: owner, deadline: deadline, window: window, action)
        }
    }

    /// Runs `action` on the main thread at `deadline` (uptime ns) within `window`
    /// (`PendingTask::earliest_delayed_run_time` / `latest_delayed_run_time`, base/pending_task.cc):
    /// `.precise` exactly at `deadline`; `.flexibleNoSooner` up to the leeway after it;
    /// `.flexiblePreferEarly` up to the leeway before it. A `deadline` that has passed runs on the next
    /// fire. A flexible sub-second window snaps to the energy policy's grid at wake time, inside its own
    /// earliest and latest times. Callable from any thread.
    @discardableResult
    public func insert(owner: String, at deadline: UInt64, window: WakeLeeway, _ action: @escaping Action) -> Token {
        state.withLock { add(&$0, owner: owner, deadline: deadline, window: window, action) }
    }

    private func add(_ state: inout State, owner: String, deadline: UInt64, window: WakeLeeway, _ action: @escaping Action) -> Token {
        state.nextID &+= 1
        let id = state.nextID
        state.heap.insert(.init(id: id, deadline: deadline, window: window, owner: owner, payload: action))
        rearm(&state)
        return Token(id: id)
    }

    /// Takes the energy policy's alignment as the leeway of new entries and the grid of pending ones, and
    /// re-arms, also to a later date (never past the top's latest time). The policy is read inside the
    /// queue's lock, so of two racing calls the later one sees the newer policy (the source updates its
    /// value before it calls observers). Called on the energy source's writer thread.
    private func realign() {
        state.withLock { state in
            let alignment = energy.policy.wakeAlignment
            guard state.alignment != alignment else { return }
            state.alignment = alignment
            state.heap.alignment = alignment.nanosecondCount
            rearm(&state)
        }
    }

    /// Drops the entry; false when it already ran or was cancelled. Re-arms the timer for the next entry
    /// (or parks it) when the entry was the one the timer waits for. Callable from any thread.
    @discardableResult
    public func cancel(_ token: Token) -> Bool {
        state.withLock { state in
            guard state.heap.remove(id: token.id) != nil else { return false }
            rearm(&state)
            return true
        }
    }

    /// The fire: runs every entry due at its start, then arms the timer for the next one.
    ///
    /// "Due" is judged at the uptime read here, as `TaskQueueImpl::MoveReadyDelayedTasksToWorkQueue` judges
    /// it with `LazyNow`, never at the armed date: a cancel on another thread may have re-armed the timer
    /// for a later entry after CFRunLoop started this fire. A fire that comes early (CF may adjust a fire
    /// date "slightly", `RunDelayedWorkTimer` in message_pump_apple.mm) runs nothing and arms again. An
    /// entry inserted meanwhile that is already due runs in the same pass.
    ///
    /// Before each entry runs, the timer is armed for what is left, so an entry that spins a nested run
    /// loop (menu tracking, a modal panel) does not stop later deadlines: the nested loop fires the timer
    /// and calls this again. The due entries left share one arm, at the fire's start.
    @MainActor
    func fire() {
        let now = state.withLock { state in
            // CFRunLoop parks a repeating timer after its callout unless something arms it again.
            state.armed = nil
            return uptime()
        }
        ledger.record(Self.ledgerOwner, reason: "fire")
        var owners = Set<String>()
        while let entry = popDue(at: now) {
            if owners.insert(entry.owner).inserted { ledger.record(entry.owner, reason: "deadline") }
            entry.payload()
        }
        state.withLock { rearm(&$0) }
    }

    /// Pops the next entry due at `now` and arms the timer for what is left.
    private func popDue(at now: UInt64) -> MainWakeUpHeap<Action>.Entry? {
        state.withLock { state in
            guard let entry = state.heap.popDue(now: now) else { return nil }
            rearm(&state, floor: now)
            return entry
        }
    }

    /// Arms the timer for the heap's wake-up, or parks it when the heap is empty. A wake-up before `floor`
    /// (default: now) arms for `floor`, so the due entries of one fire share one arm. The tolerance runs
    /// from the instant the timer can fire, the later of the date and now, to the top's latest time
    /// (zero once that has passed): CFRunLoop adds it after that instant. A re-arm to the armed date is
    /// skipped unless the new top needs a shorter tolerance.
    private func rearm(_ state: inout State, floor: UInt64? = nil) {
        guard let timer = state.timer else { return }
        guard let wakeUp = state.heap.wakeUp() else {
            if state.armed != nil {
                timer.park()
                state.armed = nil
            }
            return
        }
        let now = uptime()
        let date = max(wakeUp.date, floor ?? now)
        let fireInstant = max(date, now)
        let end = max(wakeUp.latest, fireInstant)
        if let armed = state.armed, armed.date == date, armed.end <= end { return }
        timer.arm(at: date, tolerance: end - fireInstant, now: now)
        state.armed = (date, end)
    }
}

/// The timer seam of ``MainWakeUpQueue``. It lives in the queue's `Mutex` and is called only with that
/// lock held (from any thread), so it needs no synchronization of its own and is not `Sendable`.
protocol MainWakeUpTimer: AnyObject {
    /// Fires once at `date` (uptime ns; `now` is the uptime read just before), with `tolerance` ns of
    /// slack after it.
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64)
    /// Cancels the pending fire.
    func park()
}

/// The production timer: one repeating `CFRunLoopTimer` on the main run loop in common modes (it also
/// fires during menu tracking, live resize and modal panels), parked at a far fire date between arms.
///
/// The callout does not run the fire itself; it queues it as a common-modes run-loop block, which
/// CFRunLoop runs right after its timers in the same pass. CFRunLoop never fires a timer whose callout
/// is still running, so a fire inside the callout that spins a nested run loop would stop every later
/// deadline. Chromium's `MessagePumpCFRunLoopBase::RunDelayedWorkTimer` (message_pump_mac.mm, before
/// the rename to message_pump_apple.mm) likewise signalled its work source "rather than running work
/// directly".
final class MainRunLoopWakeUpTimer: MainWakeUpTimer {
    /// Longer than any real wait: the timer repeats at this interval only so that it stays valid after a
    /// fire; every real fire date is set by `arm`.
    private static let parkedInterval: CFTimeInterval = 1.0e10
    private let timer: CFRunLoopTimer

    init(fire: @escaping MainWakeUpQueue.Action) {
        // wakeup-allow: deadline MainWakeUpQueue, the one main-thread deadline timer (parked between arms)
        timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.parkedInterval, Self.parkedInterval, 0, 0
        ) { _ in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                // main-proof: the block is queued on CFRunLoopGetMain(), whose blocks run on the main thread.
                MainActor.assumeIsolated { fire() }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    deinit {
        CFRunLoopTimerInvalidate(timer)
    }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        let delay = date > now ? Double(date - now) / 1e9 : 0
        CFRunLoopTimerSetTolerance(timer, Double(tolerance) / 1e9)
        // wakeup-allow: deadline MainWakeUpQueue, the earliest pending main-thread deadline
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + delay)
    }

    func park() {
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + Self.parkedInterval)
    }
}
