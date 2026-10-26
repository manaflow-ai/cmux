/// The ``MainWorkClass/idle`` class: tasks that run only when the main thread has nothing else to
/// do, each with a deadline (Chrome's `IdleHelper`,
/// `third_party/blink/renderer/platform/scheduler/common/idle_helper.h`;
/// plans/cmux-next/chrome-parity/p06-scheduler.md, section A).
///
/// - **Long periods** start after 50 ms of quiet: no input, no display link on the budgeted
///   scheduler (so no frame client and no budgeted work queued there) and no frame client on any
///   other scheduler. A period lasts until the earlier of 50 ms and the next main-thread deadline
///   (``deadlines``); while it stays quiet, the next one starts when it ends.
/// - **Short periods** run between frames: after a link frame's render pass, when no budgeted work
///   is held for the next frame and at least 2 ms are left before the next vsync, until 1 ms
///   before it.
/// - The budget is asked before each task (``MainFrameBudget/mayRun(_:)``): pending input ends the
///   period. A task posted from an idle task waits for the next period.
/// - A task posted with a `maxDelay` that has not run by then moves to ``MainWorkClass/background``
///   (``IdleDeadline/didTimeout``). Without one it waits for idle time, however long (Chrome's
///   `requestIdleCallback` timeout is optional and has no default).
/// - Idle periods stop 10 s after the app node goes hidden (``setAppNode(_:)``), and a task's own
///   periods stop 10 s after its node does (Chrome `kEndIdleWhenHiddenDelayMillis`); they resume
///   on show.
/// - The period timer is the scheduler's own unposted precise timer (``IdlePeriodTimer``). An
///   empty queue arms none and has no wakeups.
///
/// The app's one ``MainWorkScheduler`` owns it; post with
/// ``MainWorkScheduler/postIdle(owner:maxDelay:node:file:line:_:)``. Node times
/// (``VisibilityNode/hiddenSince``) and the budget's clock are both `CLOCK_UPTIME_RAW` in the app.
///
/// ```swift
/// work.postIdle(owner: "SpareWindow.refill", maxDelay: .milliseconds(500)) { deadline in
///     refill(until: deadline)
/// }
/// ```
@MainActor
public final class IdleScheduler {
    /// The longest idle period (Chrome `kMaximumIdlePeriodMillis`).
    public static let longPeriodLimit: Duration = .milliseconds(50)
    /// The quiet a long period waits for.
    public static let quietBeforeLongPeriod: Duration = .milliseconds(50)
    /// The time before the next vsync a short period needs.
    public static let shortPeriodMinimum: Duration = .milliseconds(2)
    /// How long before the next vsync a short period ends.
    public static let vsyncMargin: Duration = .milliseconds(1)
    /// How long after a hide idle periods go on (Chrome `kEndIdleWhenHiddenDelayMillis`).
    public static let endWhenHiddenDelay: Duration = .seconds(10)
    /// The shortest long period worth starting (Chrome `kMinimumIdlePeriodDurationMillis`).
    static let minimumPeriodNanos: UInt64 = 1_000_000

    /// Counters for `debug.main_budget` and the tests.
    public struct Stats: Sendable, Equatable {
        public var longPeriods = 0
        public var shortPeriods = 0
        /// Idle tasks run in idle periods.
        public var tasks = 0
        /// Tasks moved to background because their `maxDelay` passed.
        public var promoted = 0
        /// Tasks dropped because their node was released.
        public var dropped = 0
        /// Idle periods that pending input ended.
        public var endedByInput = 0
        /// Times the period timer fired.
        public var timerFires = 0
    }

    public private(set) var stats = Stats()
    /// The next main-thread deadline a long period must end before (the `MainDeadline` registry).
    public weak var deadlines: (any IdleNextDeadlineSource)?
    /// Posts a task past its `maxDelay` as background work (set by the ``MainWorkScheduler``).
    var promote: (@MainActor (_ owner: MainTaskOwner, _ site: MainPostSite, _ body: @escaping @MainActor () -> Void) -> Void)?

    private let budget: MainFrameBudget
    private let timer: any IdlePeriodTimer
    private let ledger: WakeupLedger
    /// Whether a frame client ticks on a scheduler other than the budgeted one (window animations).
    private let otherFramesActive: @MainActor () -> Bool
    private let uptimeNanos: () -> UInt64
    private var app: VisibilityNode?
    private var appSubscription: VisibilitySubscription?
    /// Queued tasks from ``head`` on; a slot is cleared when its task runs, moves or is dropped.
    private var slots: [Entry?] = []
    private var head = 0
    private var live = 0
    /// Queued tasks with a `maxDelay`, and with a node (their scans are skipped while zero).
    private var expiring = 0
    private var withNode = 0
    /// The budgeted display link runs: its frames give short periods, and its end starts the quiet.
    private var linkRunning = false
    private var inPeriod = false
    /// The last time the main thread was seen busy (frames, input, a post on an empty queue).
    private var lastBusy: UInt64
    /// No long period starts before this (the end of the previous one, or a deadline due first).
    private var notBefore: UInt64 = 0
    /// When the timer is armed to fire.
    private var armedAt: UInt64?

    private struct Entry {
        var owner: MainTaskOwner
        var site: MainPostSite
        var body: @MainActor (IdleDeadline) -> Void
        var expiresNanos: UInt64?
        var hasNode: Bool
        weak var node: VisibilityNode?
        /// Reschedules when the node shows again (released with the entry).
        var subscription: VisibilitySubscription?
    }

    init(budget: MainFrameBudget, timer: any IdlePeriodTimer, ledger: WakeupLedger, otherFramesActive: @escaping @MainActor () -> Bool) {
        self.budget = budget
        self.timer = timer
        self.ledger = ledger
        self.otherFramesActive = otherFramesActive
        uptimeNanos = budget.uptimeNanos
        lastBusy = budget.uptimeNanos()
    }

    /// Idle tasks queued and not run or moved yet.
    public var count: Int { live }

    /// Sets the app's visibility node: idle periods stop 10 s after it leaves visible and resume
    /// when it shows again.
    public func setAppNode(_ node: VisibilityNode?) {
        app = node
        appSubscription = node?.subscribe(owner: "IdleScheduler.app") { [weak self] _ in self?.visibilityChanged() }
        visibilityChanged()
    }

    /// Queues `body` for an idle period (see ``MainWorkScheduler/postIdle(owner:maxDelay:node:file:line:_:)``).
    func post(owner: MainTaskOwner, site: MainPostSite, maxDelay: Duration?, node: VisibilityNode?,
              _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        let now = uptimeNanos()
        // Posting on an empty queue is main-thread work: the quiet starts after it.
        if live == 0, !inPeriod { lastBusy = max(lastBusy, now) }
        let expires = maxDelay.map { now &+ MainFrameBudget.nanos($0) }
        let subscription = node?.subscribe(owner: "IdleScheduler.task") { [weak self] _ in self?.visibilityChanged() }
        slots.append(Entry(owner: owner, site: site, body: body, expiresNanos: expires, hasNode: node != nil, node: node,
                           subscription: subscription))
        live += 1
        if expires != nil { expiring += 1 }
        if node != nil { withNode += 1 }
        // A post from an idle task waits for the next period; the period's end reschedules.
        if !inPeriod { reschedule(now) }
    }

    /// A link frame's render pass ended: runs a short idle period when no budgeted work is held for
    /// the next frame and at least 2 ms are left before `vsync`, until 1 ms before it.
    func frameRendered(nextVsyncNanos vsync: UInt64, budgetedWorkHeld: Bool) {
        let now = uptimeNanos()
        lastBusy = max(lastBusy, now)
        guard !inPeriod, live > 0, !budgetedWorkHeld, !hiddenLong(app, now), vsync > now,
              vsync - now >= MainFrameBudget.nanos(Self.shortPeriodMinimum), hasRunnable(now), budget.mayRun(.idle) else { return }
        stats.shortPeriods += 1
        _ = runPeriod(until: vsync - MainFrameBudget.nanos(Self.vsyncMargin))
        reschedule(uptimeNanos())
    }

    /// A person's key or click was dispatched: the 50 ms of quiet a long period waits for starts
    /// again. An armed timer stays: when it fires early, it waits out the rest.
    public func noteInput() {
        lastBusy = max(lastBusy, uptimeNanos())
    }

    /// The app or a task's node was shown or hidden: periods resume on show.
    public func visibilityChanged() {
        reschedule(uptimeNanos())
    }

    /// The budgeted display link came or went.
    func framesChanged(running: Bool) {
        linkRunning = running
        let now = uptimeNanos()
        lastBusy = max(lastBusy, now)
        reschedule(now)
    }

    // MARK: Periods

    private enum Ending {
        case deadline
        case input
        case drained
    }

    /// Runs the tasks queued before the period (later ones wait for the next) while time is left
    /// and no input is pending. Tasks whose node is hidden past the delay stay queued, in order.
    private func runPeriod(until deadline: UInt64) -> Ending {
        inPeriod = true
        defer {
            inPeriod = false
            compact()
        }
        let end = slots.count
        let budget = budget, uptimeNanos = uptimeNanos
        for index in head..<end {
            guard let entry = slots[index] else { continue }
            if uptimeNanos() >= deadline { return .deadline }
            if dropIfReleased(index, entry) || hiddenLong(entry, uptimeNanos()) { continue }
            guard budget.mayRun(.idle) else {
                stats.endedByInput += 1
                return .input
            }
            remove(index, entry)
            stats.tasks += 1
            let idleDeadline = IdleDeadline(deadlineNanos: deadline, didTimeout: false, uptimeNanos: uptimeNanos)
            budget.run(.idle, owner: entry.owner) {
                budget.board.notePostedFrom(entry.site)
                entry.body(idleDeadline)
            }
        }
        return .drained
    }

    private func timerFired() {
        armedAt = nil
        stats.timerFires += 1
        ledger.record("IdleScheduler", reason: "period")
        // A nested run loop inside an idle task fired it: the period's end reschedules.
        guard !inPeriod else { return }
        let now = uptimeNanos()
        promoteExpired(now)
        startLongPeriod(now)
        reschedule(uptimeNanos())
    }

    private func startLongPeriod(_ now: UInt64) {
        guard !linkRunning, !hiddenLong(app, now), now >= notBefore,
              now &- lastBusy >= MainFrameBudget.nanos(Self.quietBeforeLongPeriod), hasRunnable(now) else { return }
        // An animation on another scheduler's link, or a key waiting: not quiet yet.
        guard !otherFramesActive(), budget.mayRun(.idle) else {
            lastBusy = now
            return
        }
        var length = MainFrameBudget.nanos(Self.longPeriodLimit)
        if let next = deadlines?.nextFireNanos {
            guard next > now, next - now >= Self.minimumPeriodNanos else {
                // The deadline is due first: the period waits until it fired.
                notBefore = max(next, now &+ Self.minimumPeriodNanos)
                return
            }
            length = min(length, next - now)
        }
        stats.longPeriods += 1
        let periodEnd = now &+ length
        switch runPeriod(until: periodEnd) {
        case .input: lastBusy = uptimeNanos()
        // Still quiet: the next period starts when this one ends (its nested posts run then).
        case .deadline, .drained: notBefore = periodEnd
        }
    }

    /// Arms the timer for the earlier of the next long period and the next `maxDelay`; cancels it
    /// when neither is due (an empty queue, a hidden app or node, frames running).
    private func reschedule(_ now: UInt64) {
        guard !inPeriod else { return }
        var target = earliestExpiry()
        if !linkRunning, !hiddenLong(app, now), hasRunnable(now) {
            let start = max(lastBusy &+ MainFrameBudget.nanos(Self.quietBeforeLongPeriod), notBefore)
            target = min(target ?? start, start)
        }
        guard let target else {
            if armedAt != nil {
                timer.cancel()
                armedAt = nil
            }
            return
        }
        guard armedAt != target else { return }
        armedAt = target
        timer.arm(afterNanos: target > now ? target - now : 0) { [weak self] in self?.timerFired() }
    }

    // MARK: Queue

    /// Moves every task past its `maxDelay` to the background class, in posting order.
    private func promoteExpired(_ now: UInt64) {
        guard expiring > 0, let promote else { return }
        var expired: [Entry] = []
        for index in head..<slots.count {
            guard let entry = slots[index], let expires = entry.expiresNanos, expires <= now else { continue }
            remove(index, entry)
            expired.append(entry)
        }
        compact()
        // After the walk: posting can start the budgeted link, which reschedules.
        let uptimeNanos = uptimeNanos
        for entry in expired {
            stats.promoted += 1
            let body = entry.body
            promote(entry.owner, entry.site) {
                body(IdleDeadline(deadlineNanos: 0, didTimeout: true, uptimeNanos: uptimeNanos))
            }
        }
    }

    private func earliestExpiry() -> UInt64? {
        guard expiring > 0 else { return nil }
        var earliest: UInt64?
        for index in head..<slots.count {
            guard let expires = slots[index]?.expiresNanos else { continue }
            earliest = min(earliest ?? expires, expires)
        }
        return earliest
    }

    /// Whether some queued task may run in a period now (its node, if any, not hidden past the delay).
    private func hasRunnable(_ now: UInt64) -> Bool {
        guard live > 0 else { return false }
        guard withNode > 0 else { return true }
        var found = false
        for index in head..<slots.count {
            guard let entry = slots[index], !dropIfReleased(index, entry) else { continue }
            if !hiddenLong(entry, now) {
                found = true
                break
            }
        }
        compact()
        return found
    }

    /// Drops a task whose node was released (its owner is gone); true when it did.
    private func dropIfReleased(_ index: Int, _ entry: Entry) -> Bool {
        guard entry.hasNode, entry.node == nil else { return false }
        remove(index, entry)
        stats.dropped += 1
        return true
    }

    private func hiddenLong(_ entry: Entry, _ now: UInt64) -> Bool {
        entry.hasNode && hiddenLong(entry.node, now)
    }

    /// Whether `node` left visible at least ``endWhenHiddenDelay`` ago.
    private func hiddenLong(_ node: VisibilityNode?, _ now: UInt64) -> Bool {
        guard let since = node?.hiddenSince.map(MainFrameBudget.nanos) else { return false }
        return now >= since && now - since >= MainFrameBudget.nanos(Self.endWhenHiddenDelay)
    }

    private func remove(_ index: Int, _ entry: Entry) {
        slots[index] = nil
        live -= 1
        if entry.expiresNanos != nil { expiring -= 1 }
        if entry.hasNode { withNode -= 1 }
    }

    /// Skips the cleared prefix; drops it once the queue is empty, or once it is most of the array.
    private func compact() {
        guard !inPeriod else { return }
        while head < slots.count, slots[head] == nil { head += 1 }
        if head == slots.count {
            slots.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= slots.count {
            slots.removeFirst(head)
            head = 0
        }
    }
}
