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
/// - A second heap for hidden entries (``insertHidden(owner:after:_:)``), released only in a fire at or
///   after each entry's whole uptime second, so hidden work never rides a visible fire before its boundary
///   (Blink's fenced throttled queue, `WakeUpBudgetPool::CanRunTasksAt`,
///   third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc). Blink also
///   runs tasks that fall due in the 3 ms after the wake-up (`kThrottledWakeUpDuration`); here those wait
///   for their own boundary, so a hidden owner that re-arms runs at most once per second.
///
/// ``insert(owner:after:policy:_:)`` and ``cancel(_:)`` work from any thread. They re-arm the timer only
/// when the fire date changes, earlier or later (`ScheduleDelayedWorkImpl` skips only an equal date); an
/// insert behind the top costs nothing. A fire runs due entries (``fire()`` says which) on the main actor
/// in latest-time order, with one ledger record per owner that ran (reason `deadline`, or the entry's own
/// ``LedgerReason``: none, or `deadline` only for a wake that ran that entry alone) and one
/// `MainWakeUpQueue` `fire` record per wake. A fire that stops at ``fireBudget`` goes on in the next
/// run-loop pass as the same wake: that continuation adds no `fire` record and no second record for an
/// owner that already ran. No Task and no pool thread take part.
public final class MainWakeUpQueue: Sendable {
    /// Names one pending entry for ``cancel(_:)``.
    public struct Token: Hashable, Sendable {
        let id: UInt64
    }

    /// The work of one entry. It runs on the main thread, from a run-loop block the timer's callout queues.
    public typealias Action = @MainActor @Sendable () -> Void

    /// The `WakeupLedger` owner of the queue's own wakes (reason `fire`).
    public static let ledgerOwner = "MainWakeUpQueue"
    /// The longest one fire runs entries. The entries still due run in a continuation armed for now with
    /// no tolerance, after the run loop's pending sources (an NSEvent): Chrome's UI thread runs one `DoWork`
    /// batch per `MessagePumpCFRunLoopBase::RunWork` and signals its work source again when work is left
    /// (base/message_loop/message_pump_apple.mm). The batch is 2 ms here, not the 8 ms of Chrome's
    /// `kRunTasksByBatches` (base/task/task_features.cc): a quarter of a 120 Hz frame, as the CEF pump's slice.
    public static let fireBudget = Duration.milliseconds(2)

    /// What a fire records for an entry's owner when the entry runs.
    public enum LedgerReason: Sendable, Equatable {
        /// One record per owner per fire, reason `deadline`.
        case deadline
        /// None: the action records the wake itself, with the reason only it knows when it runs (the CEF
        /// pump tells a delayed task from a kept deadline or a nested fire, as Chrome's
        /// `MessagePumpCFRunLoopBase` tells its wakes apart, base/message_loop/message_pump_apple.mm).
        case recordedByAction
        /// One `deadline` record only when the wake ran no other entry: an entry that rode another
        /// owner's wake did not cause it (a flexible deadline that exists to ride, like the busy
        /// watchdog's window end).
        case deadlineWhenAlone
    }

    /// One entry's work and what its fire records.
    private struct Queued {
        let reason: LedgerReason
        let action: Action
    }

    /// One wake's progress across the fires it takes (``fireBudget``).
    private struct Wake {
        /// Owners that have a `deadline` record in this wake.
        var owners = Set<String>()
        /// Entries run in this wake.
        var ran = 0
        /// The owner of a ``LedgerReason/deadlineWhenAlone`` entry that ran: recorded when the wake ends
        /// having run only that entry.
        var alone: String?
    }

    private struct State {
        var heap = MainWakeUpHeap<Queued>()
        /// Hidden entries, all in ``WakeLeeway/hidden(delay:)`` windows.
        var hidden = MainWakeUpHeap<Queued>()
        var nextID: UInt64 = 0
        /// The uptime the timer is armed for and the last instant its tolerance lets it fire; nil while
        /// it is parked.
        var armed: (date: UInt64, end: UInt64)?
        var timer: (any MainWakeUpTimer)?
        /// The sub-second leeway of new entries (the energy policy's `wakeAlignment`; the heap holds the grid).
        var alignment: Duration
        var energyObservation: EnergyPolicyObservation?
        /// Wakes that ran more than one entry (``coalescedFires``).
        var coalescedFires: UInt64 = 0
        /// Set while the timer is armed for the rest of a fire that stopped at ``fireBudget``. That arm is
        /// for now with no tolerance; no insert, cancel or realign moves it while an entry is left.
        var continuation: Wake?
    }

    /// The timer is armed with the lock held, so two inserts on different threads can not arm in the
    /// opposite order of their dates (a late arm would delay the earlier deadline). CFRunLoop calls a
    /// timer out with none of its own locks held, and the energy source's lock is a leaf (``realign()``
    /// reads it inside this one; the source calls observers outside its lock), so locks are always taken
    /// in the same order.
    private let state: Mutex<State>
    /// The Energy Saver policy the queue aligns its flexible entries to; an owner handed the queue follows it too (CEFEnergySaver).
    public let energy: EnergyPolicySource  // the policy it aligns to; an owner handed the queue follows it (CEFEnergySaver)
    /// Where each fire and each owner that runs in it are counted.
    let ledger: WakeupLedger
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
    public var count: Int { state.withLock { $0.heap.count + $0.hidden.count } }

    /// Now, on the queue's clock (uptime ns): the base of every deadline it is given.
    var now: UInt64 { uptime() }

    /// The sub-second grid and leeway of new flexible entries: the energy policy's `wakeAlignment`.
    var alignment: Duration { state.withLock { $0.alignment } }

    /// The uptime the timer is armed for (ns); nil while it is parked. The earliest wake of every pending
    /// entry: the next-fire value an idle period ends before (Blink's `IdleHelper` asks the same of its
    /// thread's `NextScheduledRunTime`).
    var armedDate: UInt64? { state.withLock { $0.armed?.date } }

    /// Wakes that ran more than one entry since launch: the wakes alignment saved (`debug.energy`). A
    /// queue count, not a ledger record: it is not a wake, and the ledger's `fire` record already counts
    /// each wake once. A wake split by ``fireBudget`` counts once.
    public var coalescedFires: UInt64 { state.withLock { $0.coalescedFires } }

    /// Runs `action` on the main thread `delay` from now, in the window ``WakeLeeway`` gives `delay` and
    /// `policy` at the energy policy's alignment. Callable from any thread.
    @discardableResult
    public func insert(
        owner: String, after delay: Duration, policy: DelayPolicy = .flexibleNoSooner, _ action: @escaping Action
    ) -> Token {
        let at = deadline(after: delay)
        return state.withLock { state in
            let window = WakeLeeway.window(delay: delay, policy: policy, alignment: state.alignment)
            return add(&state, owner: owner, deadline: at, window: window, action)
        }
    }

    /// Runs `action` on the main thread in the first fire at or after the whole uptime second at or after
    /// `delay` from now: a hidden node's timer. It runs in no earlier fire, even one made for a visible
    /// deadline after its own deadline. A delay of zero or less is not throttled and runs on the next fire,
    /// as Blink throttles only delayed tasks. Its one-second grid does not follow the energy alignment.
    /// Callable from any thread.
    @discardableResult
    public func insertHidden(owner: String, after delay: Duration, _ action: @escaping Action) -> Token {
        insertHidden(owner: owner, at: deadline(after: delay), action)
    }

    /// ``insertHidden(owner:after:_:)`` for a deadline given as an instant (uptime ns), so a deadline that
    /// moves between placements keeps its due time. One that has passed is not throttled and runs on the
    /// next fire.
    @discardableResult
    func insertHidden(owner: String, at deadline: UInt64, _ action: @escaping Action) -> Token {
        let now = uptime()
        guard deadline > now else { return insert(owner: owner, at: deadline, window: .window(delay: .zero), action) }
        let delay = Duration.nanoseconds(Int64(clamping: deadline - now))
        return state.withLock { state in
            let entry = MainWakeUpHeap<Queued>.Entry(
                id: nextID(&state), deadline: deadline, window: .hidden(delay: delay), owner: owner,
                payload: Queued(reason: .deadline, action: action)
            )
            state.hidden.insert(entry)
            rearm(&state)
            return Token(id: entry.id)
        }
    }

    /// Runs `action` on the main thread at `deadline` (uptime ns) within `window`
    /// (`PendingTask::earliest_delayed_run_time` / `latest_delayed_run_time`, base/pending_task.cc):
    /// `.precise` exactly at `deadline`; `.flexibleNoSooner` up to the leeway after it;
    /// `.flexiblePreferEarly` up to the leeway before it. A `deadline` that has passed runs on the next
    /// fire. A flexible sub-second window snaps to the energy policy's grid at wake time, inside its own
    /// earliest and latest times. `ledgerReason`: what the fire records for `owner` when the entry runs.
    /// Callable from any thread.
    @discardableResult
    public func insert(
        owner: String, at deadline: UInt64, window: WakeLeeway, ledgerReason: LedgerReason = .deadline,
        _ action: @escaping Action
    ) -> Token {
        state.withLock { add(&$0, owner: owner, deadline: deadline, window: window, reason: ledgerReason, action) }
    }

    private func add(
        _ state: inout State, owner: String, deadline: UInt64, window: WakeLeeway, reason: LedgerReason = .deadline,
        _ action: @escaping Action
    ) -> Token {
        let id = nextID(&state)
        let queued = Queued(reason: reason, action: action)
        state.heap.insert(.init(id: id, deadline: deadline, window: window, owner: owner, payload: queued))
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

    private func deadline(after delay: Duration) -> UInt64 {
        let (deadline, overflow) = uptime().addingReportingOverflow(delay.nanosecondCount)
        return overflow ? .max : deadline
    }

    private func nextID(_ state: inout State) -> UInt64 {
        state.nextID &+= 1
        return state.nextID
    }

    /// Drops the entry; false when it already ran or was cancelled. Re-arms the timer for the next entry
    /// (or parks it) when the entry was the one the timer waits for. Callable from any thread. The entry is
    /// freed after the lock is released: its action may hold the last reference to an owner whose deinit
    /// cancels its own entry here.
    @discardableResult
    public func cancel(_ token: Token) -> Bool {
        let removed = state.withLock { state -> MainWakeUpHeap<Queued>.Entry? in
            guard let entry = state.heap.remove(id: token.id) ?? state.hidden.remove(id: token.id) else { return nil }
            rearm(&state)
            return entry
        }
        return removed != nil
    }

    /// The fire: runs every entry due at its start, then arms the timer for the next one.
    ///
    /// A visible entry is due once its earliest time has passed and every visible entry with a smaller
    /// latest time is due too (Chrome's `WakeUpQueue` looks only at the top), so a due entry behind a top
    /// that is not due waits for the fire of that top. A hidden entry is due once its whole-second fire
    /// time has passed. The two kinds run merged in latest-time order.
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
    /// Past ``fireBudget`` the fire stops after the running entry (so at least one runs). When entries due
    /// at its start are left, it arms for now with no tolerance (``State/continuation``): they run in the
    /// next run-loop pass, after its sources. The continuation is the same wake: no new `fire` record, and
    /// one `deadline` record per owner for the whole wake.
    @MainActor
    func fire() {
        let (now, resumed) = state.withLock { state in
            // CFRunLoop parks a repeating timer after its callout unless something arms it again.
            state.armed = nil
            let resumed = state.continuation
            state.continuation = nil
            return (uptime(), resumed)
        }
        if resumed == nil { ledger.record(Self.ledgerOwner, reason: "fire") }
        var wake = resumed ?? Wake()
        var stoppedAtBudget = false
        while let entry = popDue(at: now) {
            switch entry.payload.reason {
            case .deadline:
                if wake.owners.insert(entry.owner).inserted { ledger.record(entry.owner, reason: "deadline") }
            case .deadlineWhenAlone:
                wake.alone = entry.owner
            case .recordedByAction:
                break
            }
            wake.ran += 1
            entry.payload.action()
            if uptime() &- now >= Self.fireBudget.nanosecondCount {
                stoppedAtBudget = true
                break
            }
        }
        let continues = state.withLock { state -> Bool in
            guard stoppedAtBudget, Self.dueHeap(state, at: now) != nil, let timer = state.timer else {
                if wake.ran > 1 { state.coalescedFires &+= 1 }
                rearm(&state)
                return false
            }
            let continueAt = uptime()
            timer.arm(at: continueAt, tolerance: 0, now: continueAt)
            state.armed = (continueAt, continueAt)
            state.continuation = wake
            return true
        }
        if !continues, wake.ran == 1, let owner = wake.alone { ledger.record(owner, reason: "deadline") }
    }

    /// The heap whose top runs next.
    private enum DueHeap { case visible, hidden }

    /// Which heap's top is due at `now`, as ``fire()`` judges it (merged in latest-time order); nil when
    /// neither is.
    private static func dueHeap(_ state: State, at now: UInt64) -> DueHeap? {
        let visible: UInt64? = state.heap.top.flatMap { $0.earliest <= now ? $0.latest : nil }
        let hidden: UInt64? = state.hidden.top.flatMap { $0.fireTime <= now ? $0.latest : nil }
        switch (visible, hidden) {
        case let (visible?, hidden?) where hidden < visible: return .hidden
        case (_?, _): return .visible
        case (nil, _?): return .hidden
        case (nil, nil): return nil
        }
    }

    /// Pops the next entry due at `now` and arms the timer for what is left.
    private func popDue(at now: UInt64) -> MainWakeUpHeap<Queued>.Entry? {
        state.withLock { state in
            let entry: MainWakeUpHeap<Queued>.Entry?
            switch Self.dueHeap(state, at: now) {
            case .hidden: entry = state.hidden.popReleased(now: now)
            case .visible: entry = state.heap.popDue(now: now)
            case nil: entry = nil
            }
            guard let entry else { return nil }
            rearm(&state, floor: now)
            return entry
        }
    }

    /// The earlier fire date of the two heaps, and the smaller latest time of their tops: a fire for one
    /// heap may not come after the other's top must run.
    private static func wakeUp(_ state: State) -> (date: UInt64, latest: UInt64)? {
        switch (state.heap.wakeUp(), state.hidden.wakeUp()) {
        case let (visible?, hidden?): return (min(visible.date, hidden.date), min(visible.latest, hidden.latest))
        case let (visible?, nil): return visible
        case let (nil, hidden?): return hidden
        case (nil, nil): return nil
        }
    }

    /// Arms the timer for the earlier wake-up of the two heaps, or parks it when both are empty. A wake-up before `floor`
    /// (default: now) arms for `floor`, so the due entries of one fire share one arm. The tolerance runs
    /// from the instant the timer can fire, the later of the date and now, to the top's latest time
    /// (zero once that has passed): CFRunLoop adds it after that instant. A re-arm to the armed date is
    /// skipped unless the new top needs a shorter tolerance. A continuation's arm (``State/continuation``)
    /// is already the earliest fire there can be, so it stays while an entry is left.
    private func rearm(_ state: inout State, floor: UInt64? = nil) {
        guard let timer = state.timer else { return }
        guard let wakeUp = Self.wakeUp(state) else {
            state.continuation = nil
            if state.armed != nil {
                timer.park()
                state.armed = nil
            }
            return
        }
        if state.continuation != nil, state.armed != nil { return }
        let now = uptime()
        let date = max(wakeUp.date, floor ?? now)
        let fireInstant = max(date, now)
        let end = max(wakeUp.latest, fireInstant)
        if let armed = state.armed, armed.date == date, armed.end <= end { return }
        timer.arm(at: date, tolerance: end - fireInstant, now: now)
        state.armed = (date, end)
    }
}
