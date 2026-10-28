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
/// Work names its cause (``enqueue(cause:_:)``). In a budgeted queue, work a person or the app's
/// own frontend caused is never budgeted. The person's goes to the ``InputResponsePass`` of the
/// queue's budget while the person's turn is open, so it runs before that turn's commit; otherwise
/// it, and the frontend's, runs on the next frame of the queue's scheduler with the frame-locked
/// clients, ahead of every budgeted class. The rest keeps the class budget.
/// Chrome gives a posted task its priority from what asked for it, not from the queue it is on
/// (`base/task/task_traits.h`, `TaskPriority::USER_BLOCKING`;
/// `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`,
/// `ComputePriority` raises the queues serving an input response). Unbudgeted work may run before
/// budgeted work queued earlier, so a queue mixing causes holds work that reads the current state
/// when it runs (a row patch that maps its row then), not work that must keep its order.
///
/// ```swift
/// let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: mainWork)
/// requests.enqueue { handle(request) }
/// rows.enqueue(cause: mainWork.causes.currentCause) { feed.flush() }
/// ```
@MainActor
public final class FrameBatchQueue {
    /// Names the queue in the wakeup ledger, debug.wakeups, signposts and the watchdog's records.
    public let owner: String
    /// Its work's class: ``MainWorkClass/frame`` for a frame queue, else the budgeted class.
    public let workClass: MainWorkClass
    /// The budget, class, interned owner and frame scheduler (``MainWorkScheduler/frames``, which
    /// ticks the queue's person and frontend work with the frame clients) of a budgeted queue; nil
    /// for a frame queue. The queue holds these, not the ``MainWorkScheduler``, so the scheduler can
    /// own queues of its own (``MainWorkScheduler/post(_:owner:file:line:_:)``) without a retain cycle.
    private let budgeted: (budget: MainFrameBudget, workClass: MainWorkClass, owner: MainTaskOwner, frames: FrameScheduler)?
    /// Queued work from ``head`` on (a run slot is cleared so its captures go at once); the
    /// array is compacted when it empties, or when the run prefix is most of it.
    private var pending: [Item] = []
    private var head = 0
    /// Posted continuations from ``continuationHead`` on (``appendContinuation(owner:post:_:)``): they run before
    /// ``pending``, in the order they were posted, as Blink runs a `scheduler.yield()` continuation queue ahead of the
    /// task queue of its priority (third_party/blink/renderer/platform/scheduler/public/web_scheduling_queue_type.h).
    private var continuations: [Item] = []
    private var continuationHead = 0
    private let client: FrameClient
    /// A budgeted queue's person and frontend work that the input-response pass did not take, in
    /// order: it runs whole on the next frame (``unbudgetedClient``), never under the class budget.
    private var unbudgeted: [@MainActor () -> Void] = []
    /// Ticks ``unbudgeted`` as frame work on the budgeted queue's scheduler; made with the first such
    /// work, so a queue that never gets any has one client.
    private var unbudgetedClient: FrameClient?

    /// One queued task: posted work names its own owner and post (site, enqueue time, node state),
    /// ``enqueue(_:)`` work runs as the queue's owner.
    private struct Item {
        var work: (@MainActor () -> Void)?
        var owner: MainTaskOwner?
        var post: MainTaskPost?
        /// A continuation's frame (``MainFrameBudget/frameSerial`` when it was posted): it runs in a later one.
        var frame: UInt64 = 0
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
        // frame-client: the work a person's action queued, all of it, at the next frame (main actor); key to frame
        client = FrameClient(owner: owner, isAnimation: false, rate: .motion, on: scheduler) { _ in target.queue?.drainAll() ?? false }
        target.queue = self
    }

    /// A queue of budgeted work on the app's ``MainWorkScheduler``.
    ///
    /// - Parameters:
    ///   - owner: The queue's name in the ledger and the watchdog's records (interned on the
    ///     budget's board here, once, so each task starts without a lock).
    ///   - budgeted: `userBlocking` for the rest of a person's action, `visible` for screen updates
    ///     no action of the person caused, `automation` for work an agent, the CLI or another process
    ///     asked for, `background` for work nobody sees this frame.
    ///   - work: The app's one main-thread scheduler.
    public init(owner: String, budgeted: BudgetedWorkClass, on work: MainWorkScheduler) {
        self.owner = owner
        workClass = budgeted.workClass
        self.budgeted = (work.budget, budgeted.workClass, work.budget.board.owner(owner), work.frames)
        let target = Target()
        // A budgeted client is always motion rate (FrameClient(owner:budgeted:on:onFrame:)).
        // frame-client: queued main-actor work in its class's budget each frame while work is left
        client = FrameClient(owner: owner, budgeted: budgeted, on: work) { _, _ in target.queue?.drainBudgeted() ?? false }
        target.queue = self
    }

    /// Queues `work` for the next display frame (after work queued before it). Its cause is
    /// ``ObservationCause/program``: in a budgeted queue it keeps the class budget.
    public func enqueue(_ work: @escaping @MainActor () -> Void) {
        pending.append(Item(work: work))
        client.activate()
    }

    /// Queues `work`, which `cause` caused. In a budgeted queue, ``ObservationCause/person`` work
    /// goes to the budget's ``InputResponsePass`` (it runs before the person's turn commits); when no
    /// pass takes it (none, or the person's turn is not open), it and ``ObservationCause/frontend``
    /// work run unbudgeted on the next frame, after such work queued before them. Other causes
    /// queue as ``enqueue(_:)`` does. A frame queue runs all its work every frame, whatever its cause.
    ///
    /// - Parameters:
    ///   - cause: Who caused the change `work` shows (the app's current change cause when it was made).
    ///   - work: The work.
    public func enqueue(cause: ObservationCause, _ work: @escaping @MainActor () -> Void) {
        guard cause >= .frontend, let budgeted else { return enqueue(work) }
        if cause == .person, let pass = budgeted.budget.inputResponsePass, pass.enqueue(owner: budgeted.owner, work) { return }
        unbudgeted.append(work)
        unbudgetedTicker(on: budgeted.frames).activate()
    }

    /// Work queued and not run yet (both kinds; not what the input-response pass took).
    public var count: Int { pending.count - head + continuations.count - continuationHead + unbudgeted.count }

    /// Person and frontend work waiting for the next frame in a budgeted queue.
    package var unbudgetedCount: Int { unbudgeted.count }

    /// The frame client of ``unbudgeted``, made on first use.
    private func unbudgetedTicker(on frames: FrameScheduler) -> FrameClient {
        if let unbudgetedClient { return unbudgetedClient }
        let target = Target()
        target.queue = self
        // frame-client: a budgeted queue's person and frontend work at the next frame (main actor); key to frame
        let made = FrameClient(owner: owner + ".person", isAnimation: false, rate: .motion, on: frames) { _ in
            target.queue?.drainUnbudgeted() ?? false
        }
        unbudgetedClient = made
        return made
    }

    /// Runs the person and frontend work queued before this frame, in order, unbudgeted; true
    /// while work queued meanwhile is left for the next frame.
    private func drainUnbudgeted() -> Bool {
        guard let budgeted else { return false }
        let work = unbudgeted
        unbudgeted.removeAll(keepingCapacity: true)
        for task in work { budgeted.budget.run(.frame, owner: budgeted.owner) { task() } }
        return !unbudgeted.isEmpty
    }

    // MARK: Posted work (MainWorkScheduler.post)

    /// Queues posted work as `owner`, recorded on the board and its ledger as `post` (nil: the work
    /// names its post when it runs), without waking the frame: the scheduler runs it on the next
    /// turn or calls ``activate()``.
    func append(owner: MainTaskOwner, post: MainTaskPost?, _ work: @escaping @MainActor () -> Void) {
        pending.append(Item(work: work, owner: owner, post: post))
    }

    /// Queues posted work as `owner` ahead of every task ``append(owner:post:_:)`` queued, after the continuations
    /// queued before it, and ticks on the next frame. It is stamped with the budget's frame and no drain runs it, tick
    /// or turn, until a later frame opened: the rest of a task that yielded never runs in the frame it yielded in.
    func appendContinuation(owner: MainTaskOwner, post: MainTaskPost?, _ work: @escaping @MainActor () -> Void) {
        continuations.append(Item(work: work, owner: owner, post: post, frame: budgeted?.budget.frameSerial ?? 0))
        client.activate()
    }

    /// Ticks on the next frame while work is queued (no effect while ticking).
    func activate() {
        guard pending.count > head || continuations.count > continuationHead else { return }
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
    /// scheduler let the first task start): first the continuations posted in an earlier frame,
    /// then posted tasks. The rest stays in place, ahead of work queued meanwhile, which waits for
    /// the next frame. No copy and no re-insert: a backlog of N costs O(N) over all its frames.
    /// True while work is left.
    private func drainBudgeted(limit: Int = .max) -> Bool {
        guard let budgeted else { return drainAll() }
        let budget = budgeted.budget, mainClass = budgeted.workClass
        let end = pending.count
        var ran = 0
        while ran < limit {
            let continues = continuationHead < continuations.count && continuations[continuationHead].frame < budget.frameSerial
            guard continues || head < end else { break }
            if ran > 0, !budget.mayRun(mainClass) { break }
            let item = continues ? takeContinuation() : takeHead()
            budget.run(mainClass, owner: item.owner ?? budgeted.owner, posted: item.post) { item.work?() }
            ran += 1
        }
        compact()
        return head < pending.count || continuationHead < continuations.count
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

    /// The continuation at ``continuationHead``, its slot cleared.
    private func takeContinuation() -> Item {
        let item = continuations[continuationHead]
        continuations[continuationHead] = Item()
        continuationHead += 1
        return item
    }

    /// Drops the run prefix: all of it, keeping the buffer, once the queue is empty; otherwise
    /// once it is most of the array (amortized O(1) per item under a standing backlog).
    private func compact() {
        if continuationHead == continuations.count {
            continuations.removeAll(keepingCapacity: true)
            continuationHead = 0
        }
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= pending.count {
            pending.removeFirst(head)
            head = 0
        }
    }
}
