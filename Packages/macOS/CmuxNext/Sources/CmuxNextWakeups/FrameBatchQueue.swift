/// Main-actor work run on the display frame (architecture.md 2, plans/cmux-next/main-thread-budget.md):
/// the one batch primitive behind every frame batch (the daemon store drain, the control work
/// queue, sidebar row patches, content presentation).
///
/// The queue is a ``FrameClient`` of its scheduler, active only while work is queued, so an idle
/// app has no frame wakeups. Two kinds:
/// - A frame queue (``init(owner:scheduler:)``) runs all its work every frame, unbudgeted: work a
///   person's action caused (the content a tab switch shows, the page a new tab replaces) is never
///   held or moved to a later frame. Its work runs as plain calls, with no per-item bookkeeping.
/// - A budgeted queue (``init(owner:budgeted:on:)``: daemon churn, agent and CLI requests) ticks on
///   the app's one ``MainWorkScheduler`` after the higher classes: its work one task at a time, in
///   order, while ``MainFrameBudget`` lets the class run (never while a person's input is pending),
///   and keeps the rest for the next frame. The first task of a frame always runs.
///
/// ```swift
/// let drain = FrameBatchQueue(owner: "DaemonStore.drain", budgeted: .visible, on: mainWork)
/// drain.enqueue { store.drain() }
/// ```
@MainActor
public final class FrameBatchQueue {
    /// Names the queue in the wakeup ledger, debug.wakeups, signposts and the watchdog's records.
    public let owner: String
    /// Its work's class: ``MainWorkClass/frame`` for a frame queue, else the budgeted class.
    public let workClass: MainWorkClass
    private let source: Source
    private var pending: [@MainActor () -> Void] = []
    /// Built in init (lazy because its callback captures self; no IUO).
    private lazy var client: FrameClient = {
        switch source {
        case .frame(let scheduler):
            FrameClient(owner: owner, isAnimation: false, on: scheduler) { [weak self] _ in self?.drainAll() ?? false }
        case .budgeted(let budgeted, let work, let taskOwner):
            FrameClient(owner: owner, budgeted: budgeted, on: work) { [weak self] _, budget in
                self?.drain(budget, budgeted.workClass, taskOwner) ?? false
            }
        }
    }()

    /// Where the queue's frames come from.
    private enum Source {
        case frame(FrameScheduler)
        /// The class, the app's scheduler, and the queue's owner interned on its board.
        case budgeted(BudgetedWorkClass, MainWorkScheduler, MainTaskOwner)
    }

    /// A queue of work a person's action caused: all of it every frame, unbudgeted.
    ///
    /// - Parameters:
    ///   - owner: The queue's name in the ledger and debug.wakeups.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, scheduler: FrameScheduler = .app) {
        self.owner = owner
        workClass = .frame
        source = .frame(scheduler)
        _ = client
    }

    /// A queue of budgeted work on the app's ``MainWorkScheduler``.
    ///
    /// - Parameters:
    ///   - owner: The queue's name in the ledger and the watchdog's records (interned on the
    ///     budget's board here, once, so each task starts without a lock).
    ///   - budgeted: `visible` for screen updates no action of the person caused (daemon churn),
    ///     `automation` for work an agent, the CLI or another process asked for, `background` for
    ///     work nobody sees this frame.
    ///   - work: The app's one main-thread scheduler.
    public init(owner: String, budgeted: BudgetedWorkClass, on work: MainWorkScheduler) {
        self.owner = owner
        workClass = budgeted.workClass
        source = .budgeted(budgeted, work, work.budget.board.owner(owner))
        _ = client
    }

    /// Queues `work` for the next display frame (after work queued before it).
    public func enqueue(_ work: @escaping @MainActor () -> Void) {
        pending.append(work)
        client.activate()
    }

    /// Work queued and not run yet.
    public var count: Int { pending.count }

    /// Runs queued work while the class may run (the scheduler let the first task start); keeps
    /// the rest, ahead of work queued meanwhile. True while work is left.
    private func drain(_ budget: MainFrameBudget, _ mainClass: MainWorkClass, _ taskOwner: MainTaskOwner) -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        var ran = 0
        for work in works {
            if ran > 0, !budget.mayRun(mainClass) { break }
            budget.run(mainClass, owner: taskOwner) { work() }
            ran += 1
        }
        if ran < works.count { pending.insert(contentsOf: works.dropFirst(ran), at: 0) }
        return !pending.isEmpty
    }

    /// Runs everything queued (a frame queue); true while more arrived during it.
    private func drainAll() -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        for work in works { work() }
        return !pending.isEmpty
    }
}
