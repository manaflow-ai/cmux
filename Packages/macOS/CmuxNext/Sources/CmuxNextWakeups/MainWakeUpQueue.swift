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
///
/// ``insert(owner:after:policy:_:)`` and ``cancel(_:)`` work from any thread. An insert re-arms the
/// timer only when it makes the fire date earlier; otherwise it costs no wake. A fire runs every due
/// entry on the main actor in deadline order, with one ledger record per entry (reason `deadline`) and
/// one `MainWakeUpQueue` `fire` record per wake. No Task and no pool thread take part.
public final class MainWakeUpQueue: Sendable {
    /// Names one pending entry for ``cancel(_:)``.
    public struct Token: Hashable, Sendable {
        let id: UInt64
    }

    /// The work of one entry. It runs on the main thread, inside the timer's run-loop callout.
    public typealias Action = @MainActor @Sendable () -> Void

    /// The `WakeupLedger` owner of the queue's own wakes (reason `fire`).
    public static let ledgerOwner = "MainWakeUpQueue"

    private struct State {
        var heap = MainWakeUpHeap<Action>()
        var nextID: UInt64 = 0
        /// The uptime the timer is armed for; nil while it is parked.
        var armed: UInt64?
        /// True while ``fire()`` runs: it arms the timer once at its end, so inserts made meanwhile do not.
        var firing = false
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
    ///   - ledger: Where each fire and each entry that runs are counted (`debug.wakeups`).
    ///   - uptime: Monotonic nanoseconds, `CLOCK_UPTIME_RAW` (tests inject a fake).
    public convenience init(
        alignment: Duration = WakeLeeway.defaultAlignment,
        ledger: WakeupLedger = .shared,
        uptime: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime
    ) {
        self.init(alignment: alignment, ledger: ledger, uptime: uptime, makeTimer: { MainRunLoopWakeUpTimer(fire: $0) })
    }

    /// The seam initializer: `makeTimer` gets the queue's fire callout and returns the timer it drives.
    init(
        alignment: Duration,
        ledger: WakeupLedger,
        uptime: @escaping @Sendable () -> UInt64,
        makeTimer: (@escaping Action) -> any MainWakeUpTimer
    ) {
        self.alignment = alignment
        self.ledger = ledger
        self.uptime = uptime
        let timer = makeTimer { [weak self] in self?.fire() }
        state.withLock { $0.timer = timer }
    }

    /// Entries waiting to run.
    public var count: Int { state.withLock { $0.heap.count } }

    /// Runs `action` on the main thread `delay` from now, in the window ``WakeLeeway`` gives `delay` and
    /// `policy` at the queue's alignment. Callable from any thread.
    @discardableResult
    public func insert(
        owner: String, after delay: Duration, policy: DelayPolicy = .flexibleNoSooner, _ action: @escaping Action
    ) -> Token {
        let window = WakeLeeway.window(delay: delay, policy: policy, alignment: alignment)
        let (deadline, overflow) = uptime().addingReportingOverflow(Self.nanoseconds(delay))
        return insert(owner: owner, at: overflow ? .max : deadline, window: window, action)
    }

    /// Runs `action` on the main thread at `deadline` (uptime ns) within `window`
    /// (`PendingTask::earliest_delayed_run_time` / `latest_delayed_run_time`, base/pending_task.cc):
    /// `.precise` exactly at `deadline`; `.flexibleNoSooner` up to the leeway after it;
    /// `.flexiblePreferEarly` up to the leeway before it. A `deadline` that has passed runs on the next
    /// fire. Callable from any thread.
    @discardableResult
    public func insert(owner: String, at deadline: UInt64, window: WakeLeeway, _ action: @escaping Action) -> Token {
        let (earliest, latest) = (window.earliest(deadline: deadline), window.latest(deadline: deadline))
        let grid = window.policy == .precise ? 0 : Self.nanoseconds(window.grid)
        return state.withLock { state in
            state.nextID &+= 1
            let id = state.nextID
            state.heap.insert(.init(id: id, earliest: earliest, latest: latest, grid: grid, owner: owner, payload: action))
            rearm(&state, onlyIfEarlier: true)
            return Token(id: id)
        }
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
    /// cost a second wake.
    @MainActor
    func fire() {
        let now = state.withLock { state in
            let time = max(uptime(), state.armed ?? 0)
            // CFRunLoop parks a repeating timer after its callout unless the callout arms it again.
            state.armed = nil
            state.firing = true
            return time
        }
        ledger.record(Self.ledgerOwner, reason: "fire")
        while let entry = state.withLock({ $0.heap.popDue(now: now) }) {
            ledger.record(entry.owner, reason: "deadline")
            entry.payload()
        }
        state.withLock { state in
            state.firing = false
            rearm(&state, onlyIfEarlier: false)
        }
    }

    /// Arms the timer for the heap's wake-up, or parks it when the heap is empty. Skips a re-arm to the
    /// armed date and, with `onlyIfEarlier`, any re-arm that would make the fire later.
    private func rearm(_ state: inout State, onlyIfEarlier: Bool) {
        guard !state.firing, let timer = state.timer else { return }
        guard let wakeUp = state.heap.wakeUp() else {
            if state.armed != nil {
                timer.park()
                state.armed = nil
            }
            return
        }
        if let armed = state.armed, wakeUp.date == armed || (onlyIfEarlier && wakeUp.date > armed) { return }
        timer.arm(at: wakeUp.date, tolerance: wakeUp.tolerance, now: uptime())
        state.armed = wakeUp.date
    }

    /// Whole nanoseconds of a duration; zero for a negative one, saturating at `UInt64.max`.
    static func nanoseconds(_ duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let (seconds, attoseconds) = duration.components
        guard seconds < 18_000_000_000 else { return .max }
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}

/// The timer seam of ``MainWakeUpQueue``. It lives in the queue's `Mutex` and is called only with that
/// lock held (from any thread), so it needs no synchronization of its own.
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
