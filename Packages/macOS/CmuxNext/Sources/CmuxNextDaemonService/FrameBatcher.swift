public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextWakeups

/// Runs main-actor batches once per display frame (architecture.md 2): the
/// daemon store drain, pane presentation, the control work queue, the
/// snapshot publisher and the invariant monitors each own one batcher.
///
/// A batcher is a ``FrameClient`` of ``FrameScheduler/app``: active only
/// while work is pending, so an idle app has no frame wakeups, and the
/// scheduler's stall deadline keeps work moving while the displays sleep
/// (state-audit D4).
///
/// Each batcher has a ``MainWorkClass`` (visible updates by default): the scheduler runs it after
/// the frame's frame-locked clients and higher classes, its queued work one task at a time under
/// the class's per-frame budget (``MainFrameBudget``), and keeps what is left, in order, for the
/// next frame. While a person's input is pending the batch yields, so the key or click is
/// dispatched first.
@MainActor
public final class FrameBatcher: FrameBatchScheduler, ControlFrameSource {
    private var pending: [@MainActor @Sendable () -> Void] = []
    private let owner: String
    private let scheduler: FrameScheduler
    /// The batcher's priority class.
    public let workClass: MainWorkClass
    private let budgetedClass: BudgetedWorkClass
    /// The board of the budget this batcher draws on (control requests count queued input there).
    public nonisolated let mainTaskBoard: MainTaskBoard?
    /// Built in init (lazy because its callback captures self; no IUO).
    private lazy var client = FrameClient(owner: owner, budgeted: budgetedClass, on: scheduler) { [weak self] _, budget in
        self?.drain(budget) ?? false
    }

    /// - Parameters:
    ///   - owner: Names the batcher in the wakeup ledger, debug.wakeups and the watchdog's stall records.
    ///   - workClass: `visible` for model changes that show on screen, `automation` for
    ///     control-socket work, `background` for work nobody sees this frame.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, workClass: BudgetedWorkClass = .visible, scheduler: FrameScheduler = .app) {
        self.owner = owner
        self.budgetedClass = workClass
        self.workClass = workClass.workClass
        self.scheduler = scheduler
        self.mainTaskBoard = scheduler.budget.board
        _ = client  // built here, as before
    }

    /// The budget this batcher's work draws on (the control work queue charges its requests to it).
    public var mainFrameBudget: MainFrameBudget? { scheduler.budget }

    /// Hops through the main run loop in the common modes, not a main-actor
    /// task: a native menu tracks inside a main-queue callout, where no
    /// main-actor job runs until the menu closes (``MainRunLoopHop``).
    public nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform { self.enqueue(work) }
    }

    /// The next main run loop turn, without waiting for a display frame
    /// (the control work queue's first request after idle).
    public nonisolated func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform(work)
    }

    func enqueue(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.append(work)
        client.activate()
    }

    /// Runs the pending work, one budgeted task at a time, while the class may run (the scheduler
    /// already let the first one start); keeps the rest, ahead of work queued meanwhile, for the
    /// next frame. True while work is left.
    private func drain(_ budget: MainFrameBudget) -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        var next = works.startIndex
        while next < works.endIndex {
            if next > works.startIndex, !budget.mayRun(workClass) { break }
            budget.run(workClass, owner: owner) { works[next]() }
            next += 1
        }
        if next < works.endIndex { pending.insert(contentsOf: works[next...], at: 0) }
        return !pending.isEmpty
    }
}
