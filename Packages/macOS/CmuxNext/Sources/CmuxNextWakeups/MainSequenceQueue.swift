/// A main-thread task queue of the sequence manager (plans/cmux-next/sequence-manager-DESIGN.md
/// section 2.1; Chrome `TaskQueue`, base/task/sequence_manager/task_queue.h): a FIFO with a type
/// (its priority), enable voters and an optional fence. A ``MainTaskSelector`` makes it and picks
/// its tasks.
///
/// - FIFO: tasks run in post order, except that a continuation goes to the front (``postContinuation(file:line:_:)``).
/// - Voters: the queue runs only while every voter votes enabled (visibility, freeze, startup phase).
/// - Fence: tasks enqueued after the fence wait until it is removed; the ones before it still run.
///   The queue stays FIFO: a fence never lets a later task pass an earlier one.
///
/// The queue owns its tasks. When its owner releases it they are dropped and their closures
/// released at once; the selector keeps only a weak reference.
///
/// Step S2a: nothing in the app posts here yet; S2b moves the scheduler's class queues onto it. In
/// S2c, when today's per-node `MainTaskQueue` pump layer is removed and a node's queue becomes one
/// of these, this type takes the name `MainTaskQueue`.
///
/// ```swift
/// let rows = selector.queue(.visible, owner: board.owner("sidebar.rows"))
/// rows.post { apply(patch) }
/// rows.insertFence(.now)    // later posts wait for removeFence()
/// ```
@MainActor
public final class MainSequenceQueue {
    /// Where a fence goes in the queue's enqueue order (Chrome `InsertFencePosition`).
    public enum FencePosition: Sendable {
        /// After every task posted so far: they still run, later ones wait.
        case now
        /// Before every task: nothing runs until the fence is removed.
        case beginningOfTime
    }

    /// One queued task.
    struct Item {
        var body: @MainActor () -> Void
        let site: MainPostSite
        /// Its place in the selector's enqueue order (one counter across all queues).
        let order: UInt64
        /// When it was posted, on the selector's clock.
        let enqueuedAt: Duration
    }

    /// The queue's type: its priority and the rule between queues of that priority.
    public let type: MainQueueType
    /// The owner its tasks run as.
    public let owner: MainTaskOwner
    /// The selector's round-robin turn at which this queue last gave a task (or was made).
    var lastTurn: UInt64

    private weak var selector: MainTaskSelector?
    /// Pending tasks from ``head`` on; a taken slot gets an empty body so its captures go at once.
    private var pending: [Item] = []
    private var head = 0
    private var voters = QueueVoterSet()
    /// Tasks with an enqueue order above this wait; nil when there is no fence.
    private var fence: UInt64?

    init(type: MainQueueType, owner: MainTaskOwner, selector: MainTaskSelector, turn: UInt64) {
        self.type = type
        self.owner = owner
        self.selector = selector
        lastTurn = turn
    }

    // MARK: Posting

    /// Queues `body` behind the tasks posted before it. Never inline: the caller returns first.
    ///
    /// - Parameters:
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task. The queue holds it until it runs or the queue is released.
    public func post(file: StaticString = #fileID, line: UInt = #line, _ body: @escaping @MainActor () -> Void) {
        guard let item = selector?.item(body, site: MainPostSite(file: file, line: line)) else { return }
        pending.append(item)
    }

    /// Queues `body` at the front of this queue, for a long task that yielded and continues. It takes a
    /// new enqueue order, so across queues of its priority it does not keep the yielding task's place,
    /// and a fence inserted before it holds it like any later post.
    ///
    /// - Parameters:
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The rest of the task.
    public func postContinuation(file: StaticString = #fileID, line: UInt = #line, _ body: @escaping @MainActor () -> Void) {
        guard let item = selector?.item(body, site: MainPostSite(file: file, line: line)) else { return }
        if head > 0 {
            head -= 1
            pending[head] = item
        } else {
            pending.insert(item, at: 0)
        }
    }

    /// Tasks posted and not taken yet.
    public var pendingCount: Int { pending.count - head }

    // MARK: Voters

    /// A new voter, voting enabled.
    public func makeVoter() -> QueueVoter { voters.make() }

    /// Records `voter`'s vote. While any voter votes disabled, nothing runs.
    public func setEnabled(_ enabled: Bool, by voter: QueueVoter) { _ = voters.set(enabled, by: voter) }

    /// Takes `voter`'s vote away, as if it voted enabled; later votes of it are ignored.
    public func removeVoter(_ voter: QueueVoter) { _ = voters.remove(voter) }

    /// Whether every voter votes enabled.
    public var isEnabled: Bool { voters.isEnabled }

    // MARK: Fence

    /// Puts the queue's one fence at `position`, replacing the fence it had.
    public func insertFence(_ position: FencePosition) {
        switch position {
        case .now: fence = selector?.lastOrder ?? 0
        case .beginningOfTime: fence = 0
        }
    }

    /// Removes the fence: the tasks it held may run.
    public func removeFence() { fence = nil }

    /// Whether the queue has a fence.
    public var hasFence: Bool { fence != nil }

    /// Whether the fence holds the queue's next task.
    public var isBlockedByFence: Bool {
        guard let fence, let order = headOrder else { return false }
        return order > fence
    }

    // MARK: Selection

    /// The enqueue order of the next task; the selector ranks a queue by its head only.
    var headOrder: UInt64? { head < pending.count ? pending[head].order : nil }

    /// Whether the next task may be taken now: one is pending, every voter enables the queue and no fence holds it.
    var isRunnable: Bool { head < pending.count && voters.isEnabled && !isBlockedByFence }

    /// Whether this queue goes before `other`, a queue of the same priority, by its type's rule.
    func ranksBefore(_ other: MainSequenceQueue) -> Bool {
        switch type.selection {
        case .oldestFirst: (headOrder ?? .max) < (other.headOrder ?? .max)
        case .roundRobin: lastTurn < other.lastTurn
        }
    }

    /// Removes and returns the next task (the caller checked ``isRunnable``).
    func take() -> Item {
        let item = pending[head]
        pending[head].body = {}
        head += 1
        compact()
        return item
    }

    /// Drops the taken prefix once the queue is empty, or once it is most of the array.
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
