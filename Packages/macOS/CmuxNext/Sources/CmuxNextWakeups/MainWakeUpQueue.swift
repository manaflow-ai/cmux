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
/// in latest-time order, with one ledger record per owner that ran (reason `deadline`) and one
/// `MainWakeUpQueue` `fire` record per wake. No Task and no pool thread take part.
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
        /// Hidden entries, all in ``WakeLeeway/hidden(delay:)`` windows.
        var hidden = MainWakeUpHeap<Action>()
        var nextID: UInt64 = 0
        /// The uptime the timer is armed for and the last instant its tolerance lets it fire; nil while
        /// it is parked.
        var armed: (date: UInt64, end: UInt64)?
        var timer: (any MainWakeUpTimer)?
    }

    /// The timer is armed with the lock held, so two inserts on different threads can not arm in the
    /// opposite order of their dates (a late arm would delay the earlier deadline). CFRunLoop calls a
    /// timer out with none of its own locks held, so the two locks are always taken in the same order.
    private let state = Mutex(State())
    private let alignment: Duration
    private let ledger: WakeupLedger
    private let uptime: @Sendable () -> UInt64

    /// Makes the queue and its one main run-loop timer, parked until the first insert.
    ///
    /// - Parameters:
    ///   - alignment: The sub-second grid and leeway of flexible entries (``WakeLeeway/defaultAlignment``).
    ///   - ledger: Where each fire and each owner that runs in it are counted (`debug.wakeups`).
    ///   - uptime: Monotonic nanoseconds, `CLOCK_UPTIME_RAW` (tests inject a fake).
    public convenience init(
        alignment: Duration = WakeLeeway.defaultAlignment,
        ledger: WakeupLedger = .shared,
        uptime: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime
    ) {
        self.init(alignment: alignment, ledger: ledger, uptime: uptime, makeTimer: { MainRunLoopWakeUpTimer(fire: $0) })
    }

    /// The seam initializer: `makeTimer` gets the queue's fire callout and returns the timer it drives.
    /// The timer is made inside the lock: a `@Sendable` factory called with a `Sendable` callout returns
    /// a value no other code holds, so it can move into the `Mutex` without being `Sendable` itself.
    init(
        alignment: Duration,
        ledger: WakeupLedger,
        uptime: @escaping @Sendable () -> UInt64,
        makeTimer: @Sendable (@escaping Action) -> any MainWakeUpTimer
    ) {
        self.alignment = alignment
        self.ledger = ledger
        self.uptime = uptime
        let fire: Action = { [weak self] in self?.fire() }
        state.withLock { $0.timer = makeTimer(fire) }
    }

    /// Entries waiting to run.
    public var count: Int { state.withLock { $0.heap.count + $0.hidden.count } }

    /// Runs `action` on the main thread `delay` from now, in the window ``WakeLeeway`` gives `delay` and
    /// `policy` at the queue's alignment. Callable from any thread.
    @discardableResult
    public func insert(
        owner: String, after delay: Duration, policy: DelayPolicy = .flexibleNoSooner, _ action: @escaping Action
    ) -> Token {
        let window = WakeLeeway.window(delay: delay, policy: policy, alignment: alignment)
        return insert(owner: owner, at: deadline(after: delay), window: window, action)
    }

    /// Runs `action` on the main thread in the first fire at or after the whole uptime second at or after
    /// `delay` from now: a hidden node's timer. It runs in no earlier fire, even one made for a visible
    /// deadline after its own deadline. A delay of zero or less is not throttled and runs on the next fire,
    /// as Blink throttles only delayed tasks. Callable from any thread.
    @discardableResult
    public func insertHidden(owner: String, after delay: Duration, _ action: @escaping Action) -> Token {
        guard delay > .zero else {
            return insert(owner: owner, at: deadline(after: delay), window: .window(delay: delay), action)
        }
        let at = deadline(after: delay)
        return state.withLock { state in
            let entry = MainWakeUpHeap<Action>.Entry(
                id: nextID(&state), deadline: at, window: .hidden(delay: delay), owner: owner, payload: action
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
    /// fire. Callable from any thread.
    @discardableResult
    public func insert(owner: String, at deadline: UInt64, window: WakeLeeway, _ action: @escaping Action) -> Token {
        state.withLock { state in
            let id = nextID(&state)
            state.heap.insert(.init(id: id, deadline: deadline, window: window, owner: owner, payload: action))
            rearm(&state)
            return Token(id: id)
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
    /// (or parks it) when the entry was the one the timer waits for. Callable from any thread.
    @discardableResult
    public func cancel(_ token: Token) -> Bool {
        state.withLock { state in
            if state.heap.remove(id: token.id) == nil, state.hidden.remove(id: token.id) == nil { return false }
            rearm(&state)
            return true
        }
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
            let visible: UInt64? = state.heap.top.flatMap { $0.earliest <= now ? $0.latest : nil }
            let hidden: UInt64? = state.hidden.top.flatMap { $0.fireTime <= now ? $0.latest : nil }
            let entry: MainWakeUpHeap<Action>.Entry?
            switch (visible, hidden) {
            case let (visible?, hidden?) where hidden < visible: entry = state.hidden.popReleased(now: now)
            case (_?, _): entry = state.heap.popDue(now: now)
            case (nil, _?): entry = state.hidden.popReleased(now: now)
            case (nil, nil): entry = nil
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
    /// skipped unless the new top needs a shorter tolerance.
    private func rearm(_ state: inout State, floor: UInt64? = nil) {
        guard let timer = state.timer else { return }
        guard let wakeUp = Self.wakeUp(state) else {
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
