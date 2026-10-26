/// Main-actor work run on the display frame (architecture.md 2, plans/cmux-next/main-thread-budget.md):
/// the one batch primitive behind every frame batch (the daemon store drain, the control work
/// queue, sidebar row patches, content presentation).
///
/// The queue is a ``FrameClient`` of its scheduler, active only while work is queued, so an idle
/// app has no frame wakeups. Two kinds:
/// - A frame queue (``init(owner:scheduler:)``) runs all its work every frame, unbudgeted: work a
///   person's action caused (the content a tab switch shows, the page a new tab replaces) is never
///   held or moved to a later frame. Its work runs as plain calls, with no per-item bookkeeping.
/// - A budgeted queue (``init(owner:budgeted:on:)``: agent and CLI requests) ticks on
///   the app's one ``MainWorkScheduler`` after the higher classes: its work one task at a time, in
///   order, while ``MainFrameBudget`` lets the class run (never while a person's input is pending),
///   and keeps the rest for the next frame. The first task of a frame always runs.
///
/// ```swift
/// let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: mainWork)
/// requests.enqueue { handle(request) }
/// ```
@MainActor
public final class FrameBatchQueue {
    /// Names the queue in the wakeup ledger, debug.wakeups, signposts and the watchdog's records.
    public let owner: String
    /// Its work's class: ``MainWorkClass/frame`` for a frame queue, else the budgeted class.
    public let workClass: MainWorkClass
    /// The budget, class and interned owner of a budgeted queue; nil for a frame queue. The queue
    /// holds the budget, not the scheduler, so the scheduler can own queues of its own
    /// (``MainWorkScheduler/post(_:owner:file:line:_:)``) without a retain cycle.
    private let budgeted: (budget: MainFrameBudget, workClass: MainWorkClass, owner: MainTaskOwner)?
    /// Queued work from ``head`` on (a run slot is cleared so its captures go at once); the
    /// array is compacted when it empties, or when the run prefix is most of it.
    private var pending: [Item] = []
    private var head = 0
    private let client: FrameClient

    /// One queued task: posted work names its own owner and posting site, ``enqueue(_:)`` work runs
    /// as the queue's owner.
    private struct Item {
        var work: (@MainActor () -> Void)?
        var owner: MainTaskOwner?
        var site: MainPostSite?
    }

    /// Lets the client's tick reach the queue before `self` exists (the client is built in init).
    @MainActor private final class Target {
        weak var queue: FrameBatchQueue?
    }

    /// A queue of work a person's action caused: all of it every frame, unbudgeted.
    ///
    /// - Parameters:
    ///   - owner: The queue's name in the ledger and debug.wakeups.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, scheduler: FrameScheduler = .app) {
        self.owner = owner
        workClass = .frame
        budgeted = nil
        let target = Target()
        client = FrameClient(owner: owner, isAnimation: false, on: scheduler) { _ in target.queue?.drainAll() ?? false }
        target.queue = self
    }

    /// A queue of budgeted work on the app's ``MainWorkScheduler``.
    ///
    /// - Parameters:
    ///   - owner: The queue's name in the ledger and the watchdog's records (interned on the
    ///     budget's board here, once, so each task starts without a lock).
    ///   - budgeted: `visible` for screen updates no action of the person caused,
    ///     `automation` for work an agent, the CLI or another process asked for, `background` for
    ///     work nobody sees this frame.
    ///   - work: The app's one main-thread scheduler.
    public init(owner: String, budgeted: BudgetedWorkClass, on work: MainWorkScheduler) {
        self.owner = owner
        workClass = budgeted.workClass
        self.budgeted = (work.budget, budgeted.workClass, work.budget.board.owner(owner))
        let target = Target()
        client = FrameClient(owner: owner, budgeted: budgeted, on: work) { _, _ in target.queue?.drainBudgeted() ?? false }
        target.queue = self
    }

    /// Queues `work` for the next display frame (after work queued before it).
    public func enqueue(_ work: @escaping @MainActor () -> Void) {
        pending.append(Item(work: work))
        client.activate()
    }

    /// Work queued and not run yet.
    public var count: Int { pending.count - head }

    // MARK: Posted work (MainWorkScheduler.post)

    /// Queues posted work as `owner`, recorded on the board as posted from `site`, without waking
    /// the frame: the scheduler runs it on the next turn or calls ``activate()``.
    func append(owner: MainTaskOwner, site: MainPostSite, _ work: @escaping @MainActor () -> Void) {
        pending.append(Item(work: work, owner: owner, site: site))
    }

    /// Ticks on the next frame while work is queued (no effect while ticking).
    func activate() {
        guard count > 0 else { return }
        client.activate()
    }

    /// Whether the queue ticks on frames now.
    var isActive: Bool { client.isActive }

    /// Runs at most `limit` of the queued tasks outside a tick, as a tick would (the caller checked
    /// ``MainFrameBudget/mayRun(_:)`` for the first one); true while work is left.
    func drainNow(limit: Int) -> Bool {
        drainBudgeted(limit: limit)
    }

    /// Runs the work queued before this frame, from the front, while the class may run (the
    /// scheduler let the first task start); the rest stays in place, ahead of work queued
    /// meanwhile, which waits for the next frame. No copy and no re-insert: a backlog of N costs
    /// O(N) over all its frames. True while work is left.
    private func drainBudgeted(limit: Int = .max) -> Bool {
        guard let budgeted else { return drainAll() }
        let budget = budgeted.budget, mainClass = budgeted.workClass
        let end = limit >= pending.count - head ? pending.count : head + limit
        var ran = 0
        while head < end {
            if ran > 0, !budget.mayRun(mainClass) { break }
            let item = takeHead()
            budget.run(mainClass, owner: item.owner ?? budgeted.owner) {
                if let site = item.site { budget.board.notePostedFrom(site) }
                item.work?()
            }
            ran += 1
        }
        compact()
        return head < pending.count
    }

    /// Runs everything queued before this frame (a frame queue); true while more arrived during it.
    private func drainAll() -> Bool {
        let end = pending.count
        while head < end { takeHead().work?() }
        compact()
        return head < pending.count
    }

    /// The item at ``head``, its slot cleared.
    private func takeHead() -> Item {
        let item = pending[head]
        pending[head] = Item()
        head += 1
        return item
    }

    /// Drops the run prefix: all of it, keeping the buffer, once the queue is empty; otherwise
    /// once it is most of the array (amortized O(1) per item under a standing backlog).
    private func compact() {
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= pending.count {
            pending.removeFirst(head)
            head = 0
        }
    }
}
