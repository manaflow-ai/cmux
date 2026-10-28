/// A node's task queues and its freeze (plans/cmux-next/chrome-parity/p06-scheduler.md, "Posting API").
extension VisibilityNode {
    /// A queue of `workClass` tasks that runs by this node's state (``MainTaskQueue``): held while
    /// the node is not visible (background at hidden wakes), stopped while it is frozen, dropped
    /// with the queue. Work for a hideable owner goes through its node's queue; a plain
    /// ``MainWorkScheduler/post(_:owner:file:line:_:)`` from such an owner says why with `// node-free:`.
    ///
    /// - Parameters:
    ///   - workClass: The class its tasks run in.
    ///   - owner: Its tasks' owner on the board.
    ///   - work: The app's one main-thread scheduler.
    public func queue(_ workClass: BudgetedWorkClass, owner: String, on work: MainWorkScheduler) -> MainTaskQueue {
        let queue = MainTaskQueue(node: self, workClass: workClass, owner: owner, on: work)
        queues.removeAll { $0.queue == nil }
        queues.append(WeakQueue(queue: queue))
        return queue
    }

    /// Stops this node's task queues: none of their tasks runs, visible or not, until
    /// ``unfreeze()`` (Blink's `PageSchedulerImpl::SetPageFrozen`). Child nodes are not frozen.
    public func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        notifyQueues()
    }

    /// Lets this node's task queues run again by its visibility.
    public func unfreeze() {
        guard isFrozen else { return }
        isFrozen = false
        notifyQueues()
    }

    func notifyQueues() {
        for queue in queues.compactMap(\.queue) { queue.nodeDidChange() }
    }

    struct WeakQueue {
        weak var queue: MainTaskQueue?
    }
}
