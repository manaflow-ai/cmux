/// Main-actor work run on the display frame as budgeted tasks of one class (architecture.md 2,
/// plans/cmux-next/main-thread-budget.md): the one batch primitive behind every frame batch (the
/// daemon store drain, the control work queue, sidebar row patches, the browser host's frames).
///
/// The queue is a ``FrameClient`` of its scheduler, active only while work is queued, so an idle
/// app has no frame wakeups. A ``Kind/frame`` queue runs all its work every frame, unbudgeted: work a
/// person's action caused (the content a tab switch shows, the page a new tab replaces) is never
/// held or moved to a later frame. A budgeted queue (``Kind/budgeted(_:)``: daemon churn, agent and
/// CLI requests) runs after the frame-locked clients and the higher classes: its work one task at a
/// time, in order, while ``MainFrameBudget`` lets the class run (its per-frame budget, and never
/// while a person's input is pending), and keeps the rest for the next frame. The first task of a
/// frame always runs.
///
/// ```swift
/// let frames = FrameBatchQueue(owner: "browser-host.frames", kind: .budgeted(.automation))
/// frames.enqueue { provider.handle(frame) }
/// ```
@MainActor
public final class FrameBatchQueue {
    /// How a queue's work runs per frame.
    public enum Kind: Sendable, Equatable {
        /// Every frame, all of it, unbudgeted: visible work a person's action caused.
        case frame
        /// Under a budgeted class's per-frame budget: visible work no action of the person caused
        /// (daemon churn, streaming updates), automation, background.
        case budgeted(BudgetedWorkClass)
    }

    /// Names the queue in the wakeup ledger, debug.wakeups, signposts and the watchdog's records.
    public let owner: String
    /// How its work runs.
    public let kind: Kind
    /// The scheduler whose frames run it.
    public let scheduler: FrameScheduler
    private var pending: [@MainActor () -> Void] = []
    /// Built in init (lazy because its callback captures self; no IUO).
    private lazy var client: FrameClient = {
        switch kind {
        case .frame:
            FrameClient(owner: owner, isAnimation: false, on: scheduler) { [weak self] _ in self?.drainAll() ?? false }
        case .budgeted(let workClass):
            FrameClient(owner: owner, budgeted: workClass, on: scheduler) { [weak self] _, budget in
                self?.drain(budget, workClass.workClass) ?? false
            }
        }
    }()

    /// - Parameters:
    ///   - owner: The queue's name in the ledger and the watchdog's records.
    ///   - kind: ``Kind/frame`` for work a person's action caused; budgeted `visible` for screen
    ///     updates no action of the person caused, `automation` for work an agent, the CLI or another
    ///     process asked for, `background` for work nobody sees this frame.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, kind: Kind = .frame, scheduler: FrameScheduler = .app) {
        self.owner = owner
        self.kind = kind
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
    private func drain(_ budget: MainFrameBudget, _ mainClass: MainWorkClass) -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        var ran = 0
        for work in works {
            if ran > 0, !budget.mayRun(mainClass) { break }
            budget.run(mainClass, owner: owner) { work() }
            ran += 1
        }
        if ran < works.count { pending.insert(contentsOf: works.dropFirst(ran), at: 0) }
        return !pending.isEmpty
    }

    /// Runs everything queued (a ``Kind/frame`` queue); true while more arrived during it.
    private func drainAll() -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        let budget = scheduler.budget
        for work in works { budget.run(.frame, owner: owner) { work() } }
        return !pending.isEmpty
    }
}
