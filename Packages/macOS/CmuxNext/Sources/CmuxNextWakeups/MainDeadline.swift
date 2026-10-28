/// A main-thread deadline with a class, an owner and an alignment (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E): debounces, delayed show and hide, retries, polls and request timeouts on the main actor.
///
/// It is Chromium's `base::OneShotTimer` / `base::RepeatingTimer` on a typed task runner: the wake is an entry of the
/// main thread's one ``MainWakeUpQueue``, placed by ``TimerAlignment`` through the app's ``MainDeadlineScheduler``,
/// and the action is posted on the ``MainWorkScheduler`` in ``workClass`` with ``owner`` and the creating file and
/// line, so it waits behind input and higher classes like any posted task, and the board names it while it runs.
///
/// - ``schedule(after:_:)`` replaces a pending deadline (reset); ``scheduleIfIdle(after:_:)`` keeps it.
/// - ``start(every:_:)`` repeats until ``cancel()``; the next fire is planned when the action runs, before it, as
///   `RepeatingTimer` does. A deadline scheduled again from its own action counts as repeating too.
/// - ``cancel()`` drops it, also after its wake, while its action is still waiting in its class queue.
/// - A ``TimerAlignment/whenHidden(_:)`` deadline's action is charged to ``MainWorkScheduler/hiddenBudget`` while
///   its node is hidden; with the budget spent, the wake is placed again for the first aligned wake that has budget
///   (Blink's `CPUTimeBudgetPool`). A shown node, recent media or a capture vote is not charged and never waits.
///
/// Hold it while it may fire. A released deadline never runs: its wake holds it weakly and does nothing when it comes
/// (no deinit work, as ``FrameClient``); cancel first to drop the wake.
///
/// ```swift
/// let hover = MainDeadline(owner: "Sidebar.hover", workClass: .visible, scheduler: deadlines)
/// hover.schedule(after: .milliseconds(300)) { [weak card] in card?.show() }
/// let poll = MainDeadline(owner: "Cloud.poll", workClass: .background, alignment: .whenHidden(window),
///                         scheduler: deadlines)
/// poll.start(every: .seconds(30)) { [weak cloud] in cloud?.poll() }
/// ```
@MainActor
public final class MainDeadline {
    /// The owner the board, the ledger and the signposts name.
    public let owner: String
    /// The class the action is posted in.
    public let workClass: BudgetedWorkClass
    /// How the wake may move.
    public let alignment: TimerAlignment

    private let scheduler: MainDeadlineScheduler
    private let taskOwner: MainTaskOwner
    private let file: StaticString
    private let line: UInt
    private var pending: Pending?
    /// Bumped by every schedule and cancel, so a wake or a posted action of an older plan does nothing.
    private var generation: UInt64 = 0
    private var runningAction = false
    /// A ``TimerAlignment/whenHidden(_:)`` deadline's subscriptions to its node: a visibility flip (a capture vote
    /// that does not stay hidden flips it) and media starting or stopping place the pending wake again.
    private var subscriptions: [VisibilitySubscription] = []
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Its record in the arm census (startup-queue.py arms) until its first wake.
    private var census = ArmCensusEntry()
    #endif

    private struct Pending {
        /// When it is due (uptime ns on the scheduler's queue).
        let due: UInt64
        /// The rule that placed the pending wake.
        let rule: TimerAlignment.Wake.Rule
        /// The wake on the queue or in the node's pool; nil once the action is posted.
        var handle: MainDeadlineScheduler.Handle?
        let repeating: Bool
        /// The period of ``MainDeadline/start(every:_:)``.
        let interval: Duration?
        /// The due instant before the hidden budget moved the wake, which it goes back to once the work is not charged.
        let heldDue: UInt64?
        let action: @MainActor () -> Void
    }

    /// - Parameters:
    ///   - owner: Who the deadline is for (`Sidebar.hover`, `Cloud.poll`).
    ///   - workClass: The class its action runs in: `visible` for what shows on screen, `automation` for what a
    ///     script asked for, `background` for what nobody sees.
    ///   - alignment: How its wake may move (default ``TimerAlignment/flexible``). A deadline a person or a
    ///     request waits on is never ``TimerAlignment/whenHidden(_:)``.
    ///   - scheduler: The app's one deadline scheduler.
    ///   - file: The posting file of its action (leave the default).
    ///   - line: The posting line of its action (leave the default).
    public init(owner: String, workClass: BudgetedWorkClass, alignment: TimerAlignment = .flexible,
                scheduler: MainDeadlineScheduler, file: StaticString = #fileID, line: UInt = #line) {
        self.owner = owner
        self.workClass = workClass
        self.alignment = alignment
        self.scheduler = scheduler
        taskOwner = scheduler.work.taskOwner(owner)
        self.file = file
        self.line = line
        if let node = alignment.node {
            subscriptions = [
                node.subscribe(owner: owner) { [weak self] _ in self?.replan() },
                node.subscribeExemption(owner: owner) { [weak self] in self?.replan() },
            ]
        }
    }

    /// True from a schedule until its action runs or it is cancelled.
    public var isScheduled: Bool { pending != nil }

    /// Where the pending wake fires if nothing else moves it (nil when none is pending or the action is already
    /// posted). For a deadline in its node's wake-up budget, the fire is the budget's as of now.
    public var plannedWake: TimerAlignment.Wake? {
        guard let pending, let handle = pending.handle else { return nil }
        return scheduler.wake(handle, due: pending.due, rule: pending.rule)
    }

    /// Runs `action` once, no sooner than `delay` from now, replacing any pending deadline.
    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        plan(after: delay, repeating: runningAction, interval: nil, action)
    }

    /// Schedules only when nothing is pending: a deadline that is not pushed back.
    public func scheduleIfIdle(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        schedule(after: delay, action)
    }

    /// Runs `action` every `interval` until ``cancel()``, replacing any pending deadline. The first run is
    /// `interval` from now.
    public func start(every interval: Duration, _ action: @escaping @MainActor () -> Void) {
        plan(after: interval, repeating: true, interval: interval, action)
    }

    /// Drops the pending deadline, and its action if the wake already posted it.
    public func cancel() {
        generation &+= 1
        if let handle = pending?.handle { scheduler.remove(handle) }
        pending = nil
    }

    // MARK: Internals

    private func plan(after delay: Duration, repeating: Bool, interval: Duration?,
                      _ action: @escaping @MainActor () -> Void) {
        cancel()
        #if DEBUG || CMUX_BENCH_HOOKS
        census.armed(in: scheduler.armCensus, .mainDeadline, owner: owner, site: ArmCensus.Site(file: file, line: line))
        #endif
        place(due: Self.instant(after: delay, from: scheduler.now), repeating: repeating, interval: interval, action)
    }

    /// Places the wake for `due` under the rule that applies now.
    private func place(due: UInt64, heldDue: UInt64? = nil, repeating: Bool, interval: Duration?,
                       _ action: @escaping @MainActor () -> Void) {
        let rule = scheduler.rule(alignment, due: due, repeating: repeating)
        let handle = scheduler.place(self, generation: generation, due: due, rule: rule)
        pending = Pending(due: due, rule: rule, handle: handle, repeating: repeating, interval: interval,
                          heldDue: heldDue, action: action)
    }

    /// How the action run now is charged to the hidden budget: a deadline with no node is not a hidden node's work.
    private var charge: CPUTimeBudgetPool.Charge {
        guard let node = alignment.node else { return .visible }
        return CPUTimeBudgetPool.Charge(of: node)
    }

    private static func instant(after delay: Duration, from now: UInt64) -> UInt64 {
        let (due, overflow) = now.addingReportingOverflow(delay.nanosecondCount)
        return overflow ? .max : due
    }

    /// The node flipped, or its media or capture state changed: the same due instant, under the rule that applies
    /// now (a shown node's deadline fires flexibly at once if it was due). A wake whose rule stays is not touched. A
    /// wake the hidden budget moved goes back to its own due instant once the work is no longer charged.
    private func replan() {
        guard let current = pending, let handle = current.handle else { return }
        if let heldDue = current.heldDue, charge != .hidden {
            scheduler.remove(handle)
            return place(due: heldDue, repeating: current.repeating, interval: current.interval, current.action)
        }
        guard scheduler.rule(alignment, due: current.due, repeating: current.repeating) != current.rule else { return }
        scheduler.remove(handle)
        place(due: current.due, heldDue: current.heldDue, repeating: current.repeating, interval: current.interval,
              current.action)
    }

    /// The wake came: the action is posted in its class, with the node's state for the board's ledger. It is not held
    /// for a hidden node: the wake was already aligned for one.
    func wakeDidFire(_ generation: UInt64) {
        guard generation == self.generation, pending?.handle != nil else { return }
        pending?.handle = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        census.fired(in: scheduler.armCensus)
        #endif
        let work = scheduler.work
        var node = MainTaskPost.NodeState.none
        if let owningNode = alignment.node { node = MainTaskPost.NodeState(owningNode.effective) }
        let post = MainTaskPost(site: MainPostSite(file: file, line: line), enqueueNanos: work.budget.nowNanos, node: node)
        work.post(workClass, owner: taskOwner, post: post) { [weak self] in self?.run(generation) }
    }

    private func run(_ generation: UInt64) {
        guard generation == self.generation, let current = pending else { return }
        let charge = self.charge
        let budget = scheduler.work.hiddenBudget
        let wait = budget.delayUntilAllowed(charge)
        guard wait == .zero else {
            return place(due: Self.instant(after: wait, from: scheduler.now), heldDue: current.heldDue ?? current.due,
                         repeating: current.repeating, interval: current.interval, current.action)
        }
        if let interval = current.interval {
            place(due: Self.instant(after: interval, from: scheduler.now), repeating: true, interval: interval,
                  current.action)
        } else {
            pending = nil
        }
        runningAction = true
        defer { runningAction = false }
        budget.run(charge) { current.action() }
    }
}
