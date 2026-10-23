/// Main-actor work run on the display frame as budgeted tasks of one class (architecture.md 2,
/// plans/cmux-next/main-thread-budget.md): the one batch primitive behind every frame batch (the
/// daemon store drain, the control work queue, sidebar row patches, the browser host's frames).
///
/// The queue is a ``FrameClient`` of its scheduler, active only while work is queued, so an idle
/// app has no frame wakeups. Each frame it runs after the frame-locked clients and the higher
/// classes: its work one task at a time, in order, while ``MainFrameBudget`` lets the class run
/// (its per-frame budget, and never while a person's input is pending), and keeps the rest for the
/// next frame. The first task of a frame always runs.
///
/// ```swift
/// let frames = FrameBatchQueue(owner: "browser-host.frames", workClass: .automation)
/// frames.enqueue { provider.handle(frame) }
/// ```
@MainActor
public final class FrameBatchQueue {
    /// Names the queue in the wakeup ledger, debug.wakeups, signposts and the watchdog's records.
    public let owner: String
    /// The class its work runs as.
    public let workClass: BudgetedWorkClass
    /// The scheduler whose frames run it.
    public let scheduler: FrameScheduler
    private var pending: [@MainActor () -> Void] = []
    /// Built in init (lazy because its callback captures self; no IUO).
    private lazy var client = FrameClient(owner: owner, budgeted: workClass, on: scheduler) { [weak self] _, budget in
        self?.drain(budget) ?? false
    }

    /// - Parameters:
    ///   - owner: The queue's name in the ledger and the watchdog's records.
    ///   - workClass: `visible` for model changes that show on screen, `automation` for work an
    ///     agent, the CLI or another process asked for, `background` for work nobody sees this frame.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, workClass: BudgetedWorkClass = .visible, scheduler: FrameScheduler = .app) {
        self.owner = owner
        self.workClass = workClass
        self.scheduler = scheduler
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
    private func drain(_ budget: MainFrameBudget) -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        let mainClass = workClass.workClass
        var ran = 0
        for work in works {
            if ran > 0, !budget.mayRun(mainClass) { break }
            budget.run(mainClass, owner: owner) { work() }
            ran += 1
        }
        if ran < works.count { pending.insert(contentsOf: works.dropFirst(ran), at: 0) }
        return !pending.isEmpty
    }
}
