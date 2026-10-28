/// Picks the next main-thread task across the sequence manager's queues
/// (plans/cmux-next/sequence-manager-DESIGN.md section 2.1; Chrome `TaskQueueSelector`,
/// base/task/sequence_manager/task_queue_selector.h).
///
/// The rule: strictly the highest priority (``MainQueueType/priority``) that has a runnable queue
/// the caller admits. Inside that priority, by the type's ``MainQueueType/Selection``:
/// - `oldestFirst` (control, input, frame, idle): the queue whose next task was enqueued first,
///   across queues (Chrome's rule);
/// - `roundRobin` (every budgeted type): the queue that gave a task least recently, FIFO inside each
///   queue, so a queue with 256 queued holds a later one-task queue for one task only (today's
///   budgeted frame clients and control connections; a stated difference from Chrome).
///
/// A queue is ranked by its next task only; a continuation at the front makes enqueue orders inside a
/// queue non-monotonic, and the rule never assumes they are. Enqueue times come from the injected
/// clock, never a wall clock read of its own.
///
/// Since step S2b, ``MainWorkScheduler``'s class queues are on its selector, and each class's batch takes its
/// tasks from it with the budget (``MainFrameBudget/mayRun(_:)``) as the admission (MainWorkScheduler+Batch.swift).
///
/// ```swift
/// let selector = MainTaskSelector(clock: clock)
/// let rows = selector.queue(.visible, owner: board.owner("sidebar.rows"))
/// rows.post { apply(patch) }
/// while let task = selector.takeNext(admitting: { budget.mayRun($0) }) { task.run() }
/// ```
@MainActor
public final class MainTaskSelector {
    /// A task taken from its queue, to run now.
    public struct Selected {
        /// The type of the queue it came from.
        public let type: MainQueueType
        /// Its owner: the one its post named, else its queue's.
        public let owner: MainTaskOwner
        /// Where it was posted.
        public let site: MainPostSite
        /// Its post's record for the board's ledger (site, enqueue time, node state), when its post gave one.
        public let posted: MainTaskPost?
        /// Its place in the enqueue order across all queues.
        public let order: UInt64
        /// How long it waited from its post until it was taken, on the selector's clock.
        public let waited: Duration
        fileprivate let body: @MainActor () -> Void
        fileprivate let fenceOrder: UInt64
        fileprivate weak var queue: MainSequenceQueue?

        /// Runs the task as its queue's running task, so a continuation it posts keeps its place before a
        /// fence (on main: a nested type does not take the selector's isolation).
        @MainActor public func run() {
            guard let queue else { return body() }
            queue.run(body, fenceOrder: fenceOrder)
        }
    }

    /// The last enqueue order given (0 before the first post).
    private(set) var lastOrder: UInt64 = 0
    /// Counts queue creations and takes; a queue's ``MainSequenceQueue/lastTurn`` is its last one.
    private var turn: UInt64 = 0
    private var queues: [WeakQueue] = []
    private let elapsed: () -> Duration
    private let onStrayContinuation: @MainActor (MainPostSite) -> Void

    /// - Parameters:
    ///   - clock: The manager's injected clock; tasks' enqueue times and waits are read on it.
    ///   - onStrayContinuation: Called with the site of a ``MainSequenceQueue/postContinuation(file:line:_:)``
    ///     made while no task of that queue runs; the default is ``assertInTask(_:)``.
    public init(clock: any Clock<Duration>,
                onStrayContinuation: @escaping @MainActor (MainPostSite) -> Void = MainTaskSelector.assertInTask) {
        elapsed = clock.stopwatch()
        self.onStrayContinuation = onStrayContinuation
    }

    /// The default stray-continuation report: an assertion in Debug builds, nothing in Release (the
    /// task is still queued as a plain post).
    public nonisolated static func assertInTask(_ site: MainPostSite) {
        assertionFailure("postContinuation outside a running task of its queue at \(site.file):\(site.line)")
    }

    /// A new queue of `type` for `owner`. The caller owns it; when released, its tasks go with it.
    public func queue(_ type: MainQueueType, owner: MainTaskOwner) -> MainSequenceQueue {
        turn += 1
        let queue = MainSequenceQueue(type: type, owner: owner, selector: self, turn: turn)
        queues.append(WeakQueue(queue: queue))
        return queue
    }

    /// Whether any live queue has a task that may be taken now.
    public var hasRunnableWork: Bool { queues.contains { $0.queue?.isRunnable == true } }

    /// Takes the next task by the rule, from the types `admits` lets run (the manager's budget pools and
    /// voters per type); nil when none may run.
    public func takeNext(admitting admits: (MainQueueType) -> Bool = { _ in true }) -> Selected? {
        guard let queue = select(admitting: admits) else { return nil }
        return take(from: queue)
    }

    /// Takes the next task of `queue`, which the caller found runnable, and gives `queue` this turn of the round robin
    /// (a class batch of ``MainWorkScheduler`` picks its own two queues: its continuations first).
    func take(from queue: MainSequenceQueue) -> Selected {
        let item = queue.take()
        turn += 1
        queue.lastTurn = turn
        return Selected(type: queue.type, owner: item.owner ?? queue.owner, site: item.site, posted: item.posted, order: item.order,
                        waited: elapsed() - item.enqueuedAt, body: item.body, fenceOrder: item.fenceOrder, queue: queue)
    }

    /// Takes the next task (``takeNext(admitting:)``) and runs it; false when none may run.
    @discardableResult
    public func runNext(admitting admits: (MainQueueType) -> Bool = { _ in true }) -> Bool {
        guard let task = takeNext(admitting: admits) else { return false }
        task.run()
        return true
    }

    /// A queue's new task: the next enqueue order and the time now.
    func item(_ body: @escaping @MainActor () -> Void, site: MainPostSite, owner: MainTaskOwner? = nil,
              posted: MainTaskPost? = nil) -> MainSequenceQueue.Item {
        lastOrder += 1
        return MainSequenceQueue.Item(body: body, site: site, order: lastOrder, fenceOrder: lastOrder, enqueuedAt: elapsed(),
                                      owner: owner, posted: posted)
    }

    /// Reports a continuation posted while no task of its queue runs.
    func reportStrayContinuation(_ site: MainPostSite) { onStrayContinuation(site) }

    private func select(admitting admits: (MainQueueType) -> Bool) -> MainSequenceQueue? {
        var best: MainSequenceQueue?
        var released = false
        for entry in queues {
            guard let queue = entry.queue else {
                released = true
                continue
            }
            guard queue.isRunnable, admits(queue.type) else { continue }
            guard let current = best else {
                best = queue
                continue
            }
            let priority = queue.type.priority, currentPriority = current.type.priority
            if priority < currentPriority || (priority == currentPriority && queue.ranksBefore(current)) {
                best = queue
            }
        }
        if released { queues.removeAll { $0.queue == nil } }
        return best
    }

    private struct WeakQueue {
        weak var queue: MainSequenceQueue?
    }
}
