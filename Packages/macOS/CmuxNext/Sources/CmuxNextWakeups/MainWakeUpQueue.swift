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
/// ``insert(owner:after:policy:_:)`` and ``cancel(_:)`` work from any thread. An insert re-arms the
/// timer only when it makes the fire date earlier; otherwise it costs no wake. A fire runs every due
/// entry on the main actor in deadline order, with one ledger record per entry (reason `deadline`) and
/// one `MainWakeUpQueue` `fire` record per wake, for at most ``sliceBudget``; what is left runs on a fire
/// armed for now, after the run loop has handled input. No Task and no pool thread take part.
public final class MainWakeUpQueue: Sendable {
    /// Names one pending entry for ``cancel(_:)``.
    public struct Token: Hashable, Sendable {
        let id: UInt64
    }

    /// The work of one entry. It runs on the main thread, inside the timer's run-loop callout.
    public typealias Action = @MainActor @Sendable () -> Void

    /// The `WakeupLedger` owner of the queue's own wakes (reason `fire`).
    public static let ledgerOwner = "MainWakeUpQueue"

    /// The longest one fire runs entries, in ns. Entries still due after it run on the next fire, armed
    /// for now, so input the run loop handles goes between them, as `MessagePumpCFRunLoopBase::RunWork`
    /// (base/message_loop/message_pump_apple.mm) returns to the run loop between batches of work.
    public static let sliceBudget: UInt64 = 2_000_000

    private struct State {
        var heap = MainWakeUpHeap<Action>()
        var nextID: UInt64 = 0
        /// The uptime the timer is armed for; nil while it is parked.
        var armed: UInt64?
        /// True while ``fire()`` runs: it arms the timer once at its end, so inserts made meanwhile do not.
        var firing = false
        var timer: (any MainWakeUpTimer)?
        /// A re-arm moved the fire date later (or parked the timer) since the last fire, so a fire may
        /// still come for the old date: ``fire()`` judges it at the uptime, not at ``armed``.
        var movedLater = false
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
    ///   - ledger: Where each fire and each entry that runs are counted (`debug.wakeups`).
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
        state.heap.insert(Self.entry(id: id, owner: owner, deadline: deadline, window: window, action))
        rearm(&state, onlyIfEarlier: true)
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
            rearm(&state, onlyIfEarlier: false)
        }
    }

    private static func entry(id: UInt64, owner: String, deadline: UInt64, window: WakeLeeway, _ action: @escaping Action)
        -> MainWakeUpHeap<Action>.Entry {
        .init(id: id, earliest: window.earliest(deadline: deadline), latest: window.latest(deadline: deadline),
              grid: window.policy == .precise ? 0 : window.grid.nanosecondCount, followsAlignment: followsAlignment(window),
              owner: owner, payload: action)
    }

    /// Only a flexible window below one second sits on the alignment grid (``WakeLeeway``'s table).
    private static func followsAlignment(_ window: WakeLeeway) -> Bool {
        window.policy != .precise && window.delay < WakeLeeway.wholeSecondDelay
    }

    /// Drops the entry; false when it already ran or was cancelled. Re-arms the timer for the next entry
    /// (or parks it) when the entry was the one the timer waits for. Callable from any thread.
    @discardableResult
    public func cancel(_ token: Token) -> Bool {
        state.withLock { state in
            guard state.heap.remove(id: token.id) != nil else { return false }
            rearm(&state, onlyIfEarlier: false)
            return true
        }
    }

    /// The timer's callout: runs every due entry, then arms the timer for the next one.
    ///
    /// An entry inserted while it runs (by an entry or by another thread) that is already due runs in the
    /// same pass. "Due" is judged at the armed date when the fire comes before it: the uptime to
    /// `CFAbsoluteTime` conversion can land a fire microseconds early, and a fire that ran nothing would
    /// cost a second wake. After a re-arm to a later date the fire may be for the old date, so it is
    /// judged at the uptime: no entry runs before its earliest time. After ``sliceBudget`` the fire stops
    /// and arms the timer for the next due entry, a date that has passed, so the run loop handles input
    /// first and then fires again at once.
    @MainActor
    func fire() {
        let now = state.withLock { state in
            let up = uptime()
            let time = state.movedLater ? up : max(up, state.armed ?? 0)
            // CFRunLoop parks a repeating timer after its callout unless the callout arms it again.
            state.armed = nil
            state.movedLater = false
            state.firing = true
            return time
        }
        ledger.record(Self.ledgerOwner, reason: "fire")
        let start = uptime()
        while withinSlice(since: start), let entry = state.withLock({ $0.heap.popDue(now: now) }) {
            ledger.record(entry.owner, reason: "deadline")
            entry.payload()
        }
        state.withLock { state in
            state.firing = false
            rearm(&state, onlyIfEarlier: false)
        }
    }

    /// True until ``sliceBudget`` has passed since `start`; a clock that went back counts as no time.
    private func withinSlice(since start: UInt64) -> Bool {
        let now = uptime()
        return now < start || now - start < Self.sliceBudget
    }

    /// Arms the timer for the heap's wake-up, or parks it when the heap is empty. Skips a re-arm to the
    /// armed date and, with `onlyIfEarlier`, any re-arm that would make the fire later.
    private func rearm(_ state: inout State, onlyIfEarlier: Bool) {
        guard !state.firing, let timer = state.timer else { return }
        guard let wakeUp = state.heap.wakeUp() else {
            if state.armed != nil {
                timer.park()
                state.armed = nil
                state.movedLater = true
            }
            return
        }
        if let armed = state.armed {
            if wakeUp.date == armed || (onlyIfEarlier && wakeUp.date > armed) { return }
            if wakeUp.date > armed { state.movedLater = true }
        }
        timer.arm(at: wakeUp.date, tolerance: wakeUp.tolerance, now: uptime())
        state.armed = wakeUp.date
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
            // main-proof: the timer is added only to CFRunLoopGetMain() (below), whose callouts run on the main thread.
            MainActor.assumeIsolated { fire() }
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
