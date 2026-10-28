/// The ``MainWorkClass/idle`` class: tasks that run only when the main thread has nothing else to
/// do, each with a deadline (Chrome's `IdleHelper`,
/// `third_party/blink/renderer/platform/scheduler/common/idle_helper.h`;
/// plans/cmux-next/chrome-parity/p06-scheduler.md, section A).
///
/// - **Long periods** start after 50 ms of quiet: no input, no display link on any scheduler (so
///   no frame client and no budgeted work queued), no posted budgeted work waiting and no
///   main-thread deadline due. A period lasts until the earlier of 50 ms and the next main-thread
///   deadline (``deadlines``); while it stays quiet, the next one starts when it ends.
/// - **Short periods** run between frames: after the render pass of a frame of any scheduler's
///   link, when no budgeted work is held for the next frame and at least 2 ms are left before the
///   next vsync, until 1 ms before it.
/// - Each task runs only while nothing of a higher class waits: before each one, pending input
///   (``MainFrameBudget/mayRun(_:)``), posted budgeted work, or (in a long period) a display link
///   that came up ends the period, as Chrome's sequence manager picks the higher queues between
///   idle tasks and `WillBeginFrame` ends a long idle period. A task posted from an idle task waits
///   for the next period.
/// - A period that pending input ended, or found, is retried once after 50 ms; if the input is
///   still pending then, the next period waits for its dispatch (``noteInput()``). A due deadline
///   waits for the registry's change call (``IdleNextDeadlineSource/onNextFireChange``). Neither
///   re-polls on a timer.
/// - A task posted with a `maxDelay` that has not run by then moves to ``MainWorkClass/background``
///   (``IdleDeadline/didTimeout``), as its node's background queue (``MainTaskQueue``) runs it:
///   at once while the node is visible, at the scheduler's hidden wakes or on show while it is not,
///   never once the node was released. Without a `maxDelay` it waits for idle time, however long
///   (Chrome's `requestIdleCallback` timeout is optional and has no default).
/// - Idle periods stop 10 s after the app node goes hidden (``setAppNode(_:)``), and a task's
///   own stop 10 s after its node does (Chrome `kEndIdleWhenHiddenDelayMillis`); occluded is not
///   hidden. They resume on show. A task whose node was released is dropped.
/// - The period timer is the scheduler's own unposted precise timer (``IdlePeriodTimer``). An
///   empty queue arms none and has no wakeups.
///
/// A post and a flip cost O(1) (O(log n) with a `maxDelay`): a node's tasks share one record and
/// one subscription, and wait there, not in the run queue, while it is hidden past the delay.
///
/// The app's one ``MainWorkScheduler`` owns it; post with
/// ``MainWorkScheduler/postIdle(owner:maxDelay:node:file:line:_:)``. Node times
/// (``VisibilityNode/hiddenStateSince``) and the budget's clock are both `CLOCK_UPTIME_RAW` in the app.
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

    /// Its counters since launch (``Stats``).
    public internal(set) var stats = Stats()
    /// The next main-thread deadline a long period must end before (the `MainDeadline` registry).
    public weak var deadlines: (any IdleNextDeadlineSource)? {
        didSet {
            if oldValue !== deadlines { oldValue?.onNextFireChange = nil }
            deadlines?.onNextFireChange = { [weak self] in self?.deadlinesChanged() }
            deadlinesChanged()
        }
    }

    /// Posts a task past its `maxDelay` as background work (set by the ``MainWorkScheduler``).
    var promote: (@MainActor (_ owner: MainTaskOwner, _ site: MainPostSite, _ body: @escaping @MainActor () -> Void) -> Void)?
    /// The scheduler's aligned hidden wake (``MainWorkScheduler/hiddenWake``), for promoted tasks
    /// of a node that is not visible.
    var hiddenWake: (@MainActor () -> MainWorkScheduler.HiddenWake?)?
    /// Whether budgeted work waits: a posted turn, or a budgeted frame client with work queued
    /// (set by the ``MainWorkScheduler``).
    var higherWorkPending: @MainActor () -> Bool = { false }
    /// Whether the launch lets idle periods start (``StartupPhase``: not before it settles; set by
    /// the ``MainWorkScheduler``, which calls ``reschedule()`` at the settle).
    var admitted: @MainActor () -> Bool = { true }

    private let budget: MainFrameBudget
    private let timer: any IdlePeriodTimer
    private let ledger: WakeupLedger
    let uptimeNanos: () -> UInt64
    private var app: VisibilityNode?
    private var appSubscription: VisibilitySubscription?
    /// The run queue from ``head`` on: tasks that may run in a period, in posting order. A slot is
    /// cleared when its task runs, moves or is dropped.
    var slots: [IdleTask?] = []
    var head = 0
    /// Tasks in the run queue, and tasks waiting in their node's record (hidden past the delay).
    var queued = 0
    var parked = 0
    /// Promoted tasks waiting for their node to show or for a hidden wake.
    var held = 0
    /// One record per node with queued, parked or held tasks.
    var records: [ObjectIdentifier: IdleNodeRecord] = [:]
    /// The `maxDelay` expiries of queued and parked tasks (finished ones are skipped when on top).
    var expiries = IdleExpiryHeap()
    var expiring = 0
    private var sequence: UInt64 = 0
    /// The budgeted display link runs, or another scheduler's does.
    private var linkRunning = false
    private var otherLinksRunning: Bool
    private var inPeriod = false
    private var inputHold = InputHold.none
    /// The next main-thread deadline is due: no long period until the registry reports a change.
    private var deadlineDue = false
    /// The last time the main thread was seen busy (frames, input, a post on an empty queue).
    private var lastBusy: UInt64
    /// No long period starts before this (the end of the previous one).
    private var notBefore: UInt64 = 0
    /// When the timer is armed to fire.
    private var armedAt: UInt64?

    /// What pending input did to the next long period.
    private enum InputHold {
        case none
        /// It ended or held a period: one retry after the quiet.
        case retry
        /// Still pending at the retry: wait for its dispatch (``noteInput()``).
        case waitForDispatch
    }

    init(budget: MainFrameBudget, timer: any IdlePeriodTimer, ledger: WakeupLedger, otherLinksRunning: Bool) {
        self.budget = budget
        self.timer = timer
        self.ledger = ledger
        self.otherLinksRunning = otherLinksRunning
        uptimeNanos = budget.uptimeNanos
        lastBusy = budget.uptimeNanos()
    }

    /// Idle tasks queued and not run or moved yet (a released node's tasks until they are swept).
    public var count: Int { queued + parked }

    /// The nodes the queued and held tasks are for (each has one record and one subscription).
    package var trackedNodes: Int { records.count }

    /// Clears the counters (`debug.main_budget reset`).
    public func resetStats() {
        stats = Stats()
    }

    /// Sets the app's visibility node: idle periods stop 10 s after it is hidden and resume when
    /// it shows again.
    public func setAppNode(_ node: VisibilityNode?) {
        app = node
        appSubscription = node?.subscribe(owner: "IdleScheduler.app") { [weak self] _ in self?.reschedule() }
        reschedule()
    }

    /// Queues `body` for an idle period (see ``MainWorkScheduler/postIdle(owner:maxDelay:node:file:line:_:)``).
    func post(owner: MainTaskOwner, site: MainPostSite, maxDelay: Duration?, node: VisibilityNode?,
              _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        let now = uptimeNanos()
        // Posting on an empty queue is main-thread work: the quiet starts after it.
        if count == 0, !inPeriod { lastBusy = max(lastBusy, now) }
        let expires = maxDelay.map { now &+ MainFrameBudget.nanos($0) }
        let record = node.map { self.record(for: $0) }
        sequence &+= 1
        let task = IdleTask(owner: owner, site: site, body: body, expiresNanos: expires, record: record)
        if let expires {
            expiring += 1
            expiries.push(expires, sequence, task)
        }
        if let record {
            record.tasks += 1
            if hiddenLong(record.node, now) {
                task.state = .parked
                parked += 1
                record.parked.append(task)
                // A parked task arms nothing but its expiry.
                if expires != nil, !inPeriod { reschedule(now) }
                return
            }
        }
        task.state = .queued
        queued += 1
        slots.append(task)
        // A post from an idle task waits for the next period; the period's end reschedules.
        if !inPeriod { reschedule(now) }
    }

    /// A link frame's render pass ended: runs a short idle period when no budgeted work is held for
    /// the next frame and at least 2 ms are left before `vsync`, until 1 ms before it.
    func frameRendered(nextVsyncNanos vsync: UInt64, budgetedWorkHeld: Bool) {
        let now = uptimeNanos()
        lastBusy = max(lastBusy, now)
        guard !inPeriod, queued > 0, !budgetedWorkHeld, admitted(), !hiddenLong(app, now), vsync > now,
              vsync - now >= MainFrameBudget.nanos(Self.shortPeriodMinimum), !higherWorkPending(), budget.mayRun(.idle) else { return }
        stats.shortPeriods += 1
        if runPeriod(.short, until: vsync - MainFrameBudget.nanos(Self.vsyncMargin)) == .drained { sweepReleased() }
        reschedule()
    }

    /// A person's key, click, scroll or drag was dispatched: the 50 ms of quiet a long period
    /// waits for starts again, and a period that waits for pending input's dispatch may come. An
    /// armed timer stays: when it fires early, it waits out the rest.
    public func noteInput() {
        lastBusy = max(lastBusy, uptimeNanos())
        guard inputHold != .none else { return }
        inputHold = .none
        reschedule()
    }

    /// The budgeted display link came or went.
    func framesChanged(running: Bool) {
        linkRunning = running
        lastBusy = max(lastBusy, uptimeNanos())
        reschedule()
    }

    /// The first display link of another scheduler came, or the last one went.
    func otherLinksChanged(running: Bool) {
        otherLinksRunning = running
        lastBusy = max(lastBusy, uptimeNanos())
        reschedule()
    }

    private func deadlinesChanged() {
        deadlineDue = false
        reschedule()
    }

    // MARK: Periods

    private enum PeriodKind {
        case long
        case short
    }

    private enum Ending {
        case deadline
        case input
        case higherWork
        case drained
    }

    /// Runs the tasks queued before the period (later ones wait for the next) while time is left
    /// and nothing of a higher class waits. A task whose node is hidden past the delay moves to its
    /// node's record; one whose node was released is dropped.
    private func runPeriod(_ kind: PeriodKind, until deadline: UInt64) -> Ending {
        inPeriod = true
        defer {
            inPeriod = false
            compact()
        }
        let end = slots.count
        let budget = budget, uptimeNanos = uptimeNanos
        for index in head..<end {
            guard let task = slots[index] else { continue }
            guard task.state == .queued else {
                slots[index] = nil
                continue
            }
            let now = uptimeNanos()
            if now >= deadline { return .deadline }
            if let record = task.record {
                if record.node == nil {
                    slots[index] = nil
                    drop(task)
                    continue
                }
                if hiddenLong(record.node, now) {
                    slots[index] = nil
                    task.state = .parked
                    queued -= 1
                    parked += 1
                    record.parked.append(task)
                    continue
                }
            }
            if higherWorkPending() || (kind == .long && (linkRunning || otherLinksRunning)) {
                stats.endedByHigherWork += 1
                return .higherWork
            }
            guard budget.mayRun(.idle) else {
                stats.endedByInput += 1
                return .input
            }
            slots[index] = nil
            finish(task)
            let body = task.body, site = task.site
            task.body = nil
            if let record = task.record { releaseIfEmpty(record) }
            stats.tasks += 1
            let idleDeadline = IdleDeadline(deadlineNanos: deadline, didTimeout: false, uptimeNanos: uptimeNanos)
            budget.run(.idle, owner: task.owner) {
                budget.noteIdleTask(postedFrom: site, deadlineNanos: deadline)
                body?(idleDeadline)
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
        reschedule()
    }

    private func startLongPeriod(_ now: UInt64) {
        guard longPeriodMayCome(now), now >= notBefore, now &- lastBusy >= MainFrameBudget.nanos(Self.quietBeforeLongPeriod) else { return }
        // A posted turn or a budgeted batch goes first; the quiet starts after it.
        guard !higherWorkPending() else {
            lastBusy = now
            return
        }
        guard budget.mayRun(.idle) else {
            holdForInput(now)
            return
        }
        inputHold = .none
        var length = MainFrameBudget.nanos(Self.longPeriodLimit)
        if let next = deadlines?.nextFireNanos {
            guard next > now, next - now >= Self.minimumPeriodNanos else {
                // Due first: the registry's change call lets the next period start.
                deadlineDue = true
                deadlines?.watchDueFire()
                return
            }
            length = min(length, next - now)
        }
        stats.longPeriods += 1
        let periodEnd = now &+ length
        switch runPeriod(.long, until: periodEnd) {
        case .input: holdForInput(uptimeNanos())
        case .higherWork: lastBusy = uptimeNanos()
        // Still quiet: the next period starts when this one ends (its nested posts run then).
        case .deadline: notBefore = periodEnd
        case .drained:
            notBefore = periodEnd
            sweepReleased()
        }
    }

    /// Pending input ended or held a period: retry once after the quiet, then wait for its dispatch.
    private func holdForInput(_ now: UInt64) {
        lastBusy = now
        inputHold = inputHold == .none ? .retry : .waitForDispatch
    }

    /// Whether a long period can come without a new event: run-queue work, the launch settled, no
    /// link on any scheduler, no pending input past its retry, no due deadline and the app not hidden long.
    private func longPeriodMayCome(_ now: UInt64) -> Bool {
        queued > 0 && admitted() && !linkRunning && !otherLinksRunning && inputHold != .waitForDispatch && !(deadlineDue && deadlines != nil)
            && !hiddenLong(app, now)
    }

    /// Arms the timer for the earlier of the next long period and the next `maxDelay`; cancels it
    /// when neither is due (an empty run queue, a hidden app, frames running, input or a deadline
    /// waited for).
    func reschedule() {
        guard !inPeriod else { return }
        reschedule(uptimeNanos())
    }

    private func reschedule(_ now: UInt64) {
        var target = earliestExpiry()
        if longPeriodMayCome(now) {
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

    /// Whether `node` is hidden (not merely occluded) for at least ``endWhenHiddenDelay``.
    private func hiddenLong(_ node: VisibilityNode?, _ now: UInt64) -> Bool {
        guard let since = node?.hiddenStateSince.map(MainFrameBudget.nanos) else { return false }
        return now >= since && now - since >= MainFrameBudget.nanos(Self.endWhenHiddenDelay)
    }

    /// Skips the finished prefix; drops it once the queue is empty, or once it is most of the array.
    func compact() {
        guard !inPeriod else { return }
        while head < slots.count, slots[head]?.state != .queued {
            slots[head] = nil
            head += 1
        }
        if head == slots.count {
            slots.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= slots.count {
            slots.removeFirst(head)
            head = 0
        }
    }
}
