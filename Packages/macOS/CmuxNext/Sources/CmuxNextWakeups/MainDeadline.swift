/// A main-thread deadline with a class, an owner and an alignment (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E): debounces, delayed show and hide, retries, polls and request timeouts on the main actor.
///
/// It is Chromium's `base::OneShotTimer` / `base::RepeatingTimer` on a typed task runner: the wake comes from the
/// app's one ``MainDeadlineScheduler`` (one sleep for every deadline, placed by ``TimerAlignment``), and the action is
/// posted on the ``MainWorkScheduler`` in ``workClass`` with ``owner`` and the creating file and line, so it waits
/// behind input and higher classes like any posted task, and the board names it while it runs.
///
/// - ``schedule(after:_:)`` replaces a pending deadline (reset); ``scheduleIfIdle(after:_:)`` keeps it.
/// - ``start(every:_:)`` repeats until ``cancel()``; the next fire is planned when the action runs, before it, as
///   `RepeatingTimer` does. A deadline scheduled again from its own action counts as repeating too.
/// - ``cancel()`` drops it, also after its wake, while its action is still waiting in its class queue.
///
/// Hold it while it may fire. A released deadline never runs: the scheduler holds it weakly and drops its wake at
/// the next re-arm or at the wake itself (no deinit work, as ``FrameClient``); cancel first to drop the wake at once.
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
    /// A ``TimerAlignment/whenHidden(_:)`` deadline's subscription to its node: a flip re-plans the pending wake.
    private var visibility: VisibilitySubscription?

    private struct Pending {
        /// The scheduler's entry while the wake is pending; nil once the action is posted.
        var entry: UInt64?
        var wake: TimerAlignment.Wake
        let repeating: Bool
        /// The period of ``MainDeadline/start(every:_:)``.
        let interval: Duration?
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
        visibility = alignment.node?.subscribe(owner: owner) { [weak self] _ in self?.replan() }
    }

    /// True from a schedule until its action runs or it is cancelled.
    public var isScheduled: Bool { pending != nil }

    /// Where the pending wake fires (nil when none is pending or the action is already posted).
    public var plannedWake: TimerAlignment.Wake? {
        guard let pending, pending.entry != nil else { return nil }
        return pending.wake
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
        if let entry = pending?.entry { scheduler.remove(entry) }
        pending = nil
    }

    // MARK: Internals

    private func plan(after delay: Duration, repeating: Bool, interval: Duration?,
                      _ action: @escaping @MainActor () -> Void) {
        cancel()
        let wake = scheduler.wake(alignment, due: scheduler.now + max(delay, .zero), repeating: repeating)
        pending = Pending(entry: nil, wake: wake, repeating: repeating, interval: interval, action: action)
        arm()
    }

    /// Hands the pending wake to the scheduler.
    private func arm() {
        guard let wake = pending?.wake else { return }
        pending?.entry = scheduler.insert(self, generation: generation, wake: wake)
    }

    /// The node flipped: the same due instant, under the rule that applies now (a shown node's deadline fires
    /// flexibly at once if it was due).
    private func replan() {
        guard let pending, let entry = pending.entry else { return }
        let wake = scheduler.wake(alignment, due: pending.wake.due, repeating: pending.repeating)
        self.pending?.wake = wake
        scheduler.replan(entry, wake: wake)
    }

    /// The wake came: the action is posted in its class, with the node's state for the board's ledger. It is not held
    /// for a hidden node: the wake was already aligned for one.
    func wakeDidFire(_ generation: UInt64) {
        guard generation == self.generation, pending != nil else { return }
        pending?.entry = nil
        let work = scheduler.work
        var node = MainTaskPost.NodeState.none
        if let owningNode = alignment.node { node = MainTaskPost.NodeState(owningNode.effective) }
        let post = MainTaskPost(site: MainPostSite(file: file, line: line), enqueueNanos: work.budget.nowNanos, node: node)
        work.post(workClass, owner: taskOwner, post: post) { [weak self] in self?.run(generation) }
    }

    private func run(_ generation: UInt64) {
        guard generation == self.generation, let current = pending else { return }
        if let interval = current.interval {
            let wake = scheduler.wake(alignment, due: scheduler.now + interval, repeating: true)
            pending?.wake = wake
            arm()
        } else {
            pending = nil
        }
        runningAction = true
        defer { runningAction = false }
        current.action()
    }
}
