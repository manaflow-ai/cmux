/// A task queue tied to one ``VisibilityNode`` (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Posting API", task 209): Blink's per-frame task queues (`FrameSchedulerImpl`, the throttleable,
/// freezable and pausable queues behind voters in
/// third_party/blink/renderer/platform/scheduler/main_thread/frame_scheduler_impl.h), on cmux's
/// main-thread scheduler.
///
/// Work posted here runs in its class on the ``MainWorkScheduler`` (in class order, within the
/// class budget, yielding to a person's input) while the queue may run. Whether it may run depends
/// on the node:
/// - Visible, or held by a capture vote (``VisibilityNode/wantsFrames``): every task runs, in post order.
/// - Hidden or occluded: `visible` and `automation` tasks are held until the node shows; nothing a
///   person cannot see is drawn or applied for them. `background` tasks run at the scheduler's
///   aligned hidden wakes (``MainWorkScheduler/hiddenWake``; 1 s, Blink's `WakeUpBudgetPool`
///   alignment), or are held when the app installs none. Their run time is charged to the
///   scheduler's ``MainWorkScheduler/hiddenBudget``; while it is spent they wait for the first wake
///   that has budget (Blink's `CPUTimeBudgetPool`, cpu_time_budget_pool.h).
/// - Hidden with media in the last 30 s or a capture vote: `background` tasks run at once and are not
///   charged, as Blink takes such a page out of its throttling.
/// - Frozen (``VisibilityNode/freeze()``): nothing runs, not even at a wake (Blink's
///   `PageSchedulerImpl::SetPageFrozen`).
/// - Disabled by a voter (``makeVoter()``): nothing runs until every voter enables it again
///   (`base::sequence_manager::TaskQueue::QueueEnabledVoter`, base/task/sequence_manager/task_queue.h).
///
/// A post with a key replaces the pending task with the same key: it keeps its place and runs the
/// newer body, so 100 title updates while hidden run once on show. When the node shows, the held
/// tasks run in the next turn or frame, in post order, before any task posted to this queue after
/// them.
///
/// The queue owns its tasks. When it is released they are dropped and their closures released at
/// once; nothing of them stays queued on the scheduler. Blink keeps a detached frame's runners
/// alive because script can still reach them; a cmux queue's owner is a view or a model that is
/// gone, and its work has nothing left to change.
///
/// ```swift
/// let titles = tabNode.queue(.visible, owner: "Tab.title", on: mainWork)
/// titles.post(key: "title") { [weak tab] in tab?.applyTitle() }
/// ```
@MainActor
public final class MainTaskQueue {
    /// The node whose state decides when this queue runs.
    public let node: VisibilityNode
    /// The class its tasks run in.
    public let workClass: BudgetedWorkClass
    /// The owner its tasks run as on the board, in signposts and in the watchdog's records.
    public let owner: MainTaskOwner

    private let work: MainWorkScheduler
    /// Pending tasks from ``head`` on; a run slot is cleared so its captures go at once.
    private var pending: [Item] = []
    private var head = 0
    /// How many items were removed from the front of ``pending`` by compaction, so an item's
    /// absolute index (kept in ``keyed``) is its array index plus this.
    private var dropped = 0
    /// The absolute index of the pending task for each key.
    private var keyed: [AnyHashable: Int] = [:]
    /// Pump tasks posted on the scheduler that have not run yet. Each runs at most one task.
    private var pumps = 0
    /// How many head tasks the last hidden wake let run while the node stays hidden (background).
    private var released = 0
    private var wakeRequested = false
    private var voters = QueueVoterSet()
    private var runsByNodeState = [0, 0, 0]
    /// A background queue's watch of media on its node, which exempts its tasks from the hidden budget.
    private var exemption: VisibilitySubscription?

    private struct Item {
        var work: (@MainActor () -> Void)?
        var key: AnyHashable?
        /// Its site and enqueue time; the node state is filled in when it runs.
        var post: MainTaskPost
    }

    init(node: VisibilityNode, workClass: BudgetedWorkClass, owner: String, on work: MainWorkScheduler) {
        self.node = node
        self.workClass = workClass
        self.work = work
        self.owner = work.taskOwner(owner)
        if workClass == .background {
            exemption = node.subscribeExemption(owner: owner) { [weak self] in self?.schedule() }
        }
    }

    // MARK: Posting

    /// Queues `body` behind the tasks posted before it. Never inline: the caller returns first.
    ///
    /// - Parameters:
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task. The queue holds it until it runs or the queue is released.
    public func post(file: StaticString = #fileID, line: UInt = #line, _ body: @escaping @MainActor () -> Void) {
        append(Item(work: body, key: nil, post: MainTaskPost(site: MainPostSite(file: file, line: line), enqueueNanos: work.budget.nowNanos)))
    }

    /// Queues `body`, or replaces the body of the pending task posted with the same `key` (which
    /// keeps its place in the queue).
    ///
    /// - Parameters:
    ///   - key: What the task updates; the latest body for a key is the only one that runs.
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task.
    public func post(key: some Hashable, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor () -> Void) {
        let key = AnyHashable(key)
        let site = MainPostSite(file: file, line: line)
        if let index = keyed[key] {
            // The pending task keeps its place and its enqueue time: its wait counts from the first post.
            let held = pending[index - dropped].post
            pending[index - dropped].work = body
            pending[index - dropped].post = MainTaskPost(site: site, enqueueNanos: held.enqueueNanos)
            return
        }
        keyed[key] = dropped + pending.count
        append(Item(work: body, key: key, post: MainTaskPost(site: site, enqueueNanos: work.budget.nowNanos)))
    }

    /// Tasks posted and not run yet (keyed posts count once).
    public var pendingCount: Int { pending.count - head }

    /// Whether the node's state or a voter keeps the pending tasks from running now.
    public var isHolding: Bool { pendingCount > 0 && !mayRunNow }

    /// How many tasks ran while the node's effective state was `state` (diagnostics and tests:
    /// a `visible` or `automation` queue never runs a task while its node is not visible).
    public func runCount(whileNode state: Visibility) -> Int { runsByNodeState[state.rawValue] }

    // MARK: Voters

    /// A new voter, voting enabled.
    public func makeVoter() -> QueueVoter { voters.make() }

    /// Records `voter`'s vote. While any voter votes disabled, nothing runs.
    public func setEnabled(_ enabled: Bool, by voter: QueueVoter) {
        if voters.set(enabled, by: voter) { schedule() }
    }

    /// Takes `voter`'s vote away, as if it voted enabled; later votes of it are ignored.
    public func removeVoter(_ voter: QueueVoter) {
        if voters.remove(voter) { schedule() }
    }

    /// Whether every voter votes enabled.
    public var isEnabled: Bool { voters.isEnabled }

    // MARK: Node changes

    /// The node flipped, a capture vote came or went, or the node froze or unfroze (``VisibilityNode`` calls it).
    func nodeDidChange() {
        if node.wantsFrames { released = 0 }
        schedule()
    }

    // MARK: Running

    private var mayRunNow: Bool {
        guard isEnabled, !node.isFrozen else { return false }
        return node.wantsFrames || released > 0 || (workClass == .background && charge == .exempt)
    }

    /// How a task run now is charged to the hidden budget.
    private var charge: CPUTimeBudgetPool.Charge { CPUTimeBudgetPool.Charge(of: node) }

    private func append(_ item: Item) {
        pending.append(item)
        schedule()
    }

    /// Makes sure a pump is posted for every task that may run now; asks for a hidden wake for
    /// background tasks that may not.
    private func schedule() {
        guard pendingCount > 0, isEnabled, !node.isFrozen else { return }
        if node.wantsFrames {
            postPumps(upTo: pendingCount)
        } else if workClass == .background {
            if charge == .exempt {
                postPumps(upTo: pendingCount)
            } else if released > 0 {
                postPumps(upTo: released)
            } else {
                requestHiddenWake()
            }
        }
    }

    /// Pumps carry no post: the one that runs a task names that task's post
    /// (``MainFrameBudget/notePost(_:)``), and one that runs none stays out of the ledger.
    private func postPumps(upTo wanted: Int) {
        let budget = work.budget
        while pumps < min(wanted, pendingCount) {
            pumps += 1
            work.post(workClass, owner: owner, post: nil) { [weak self] in
                guard let self else { return budget.noteRanNothing() }
                pump()
            }
        }
    }

    /// One scheduler task: runs the head task if the queue may run now and a hidden one has budget,
    /// else leaves it held for the next wake.
    private func pump() {
        pumps -= 1
        guard pendingCount > 0, mayRunNow else {
            work.budget.noteRanNothing()
            return schedule()
        }
        let charge = self.charge
        if charge == .hidden, !work.hiddenBudget.mayRun(.hidden) {
            released = 0
            work.budget.noteRanNothing()
            return schedule()
        }
        if !node.wantsFrames, released > 0 { released -= 1 }
        let item = pending[head]
        pending[head] = Item(work: nil, key: nil, post: item.post)
        head += 1
        if let key = item.key { keyed[key] = nil }
        compact()
        work.budget.notePost(item.post.starting(in: MainTaskPost.NodeState(node.effective)))
        runsByNodeState[node.effective.rawValue] += 1
        work.hiddenBudget.run(charge) { item.work?() }
        if charge == .hidden, released == 0 { schedule() }
    }

    private func requestHiddenWake() {
        guard !wakeRequested, let wake = work.hiddenWake else { return }
        wakeRequested = true
        wake(owner.name) { [weak self] in self?.hiddenWakeFired() }
    }

    /// A hidden wake: the background tasks pending now may run, one scheduler task each; tasks
    /// posted after it wait for the next wake. With the hidden budget spent, none is released and
    /// ``schedule()`` asks for the next wake.
    private func hiddenWakeFired() {
        wakeRequested = false
        guard !node.wantsFrames else { return }
        if charge == .hidden { released = work.hiddenBudget.mayRun(.hidden) ? pendingCount : 0 }
        schedule()
    }

    /// Drops the run prefix once the queue is empty, or once it is most of the array.
    private func compact() {
        if head == pending.count {
            dropped += head
            pending.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= pending.count {
            dropped += head
            pending.removeFirst(head)
            head = 0
        }
    }
}
