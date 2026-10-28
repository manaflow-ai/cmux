extension MainWorkScheduler {
    /// One budgeted class's posted work on the sequence manager's queues (plans/cmux-next/sequence-manager-DESIGN.md
    /// 2.1 and 2.3, step S2b): two ``MainSequenceQueue``s of the class's type on the scheduler's ``MainTaskSelector``,
    /// one for posts and one for continuations, and the class's budgeted ``FrameClient``, which runs the class's batch
    /// in the tick (today's placement, cmux-ad Q2) after the higher classes, in turn with the other budgeted clients
    /// of the class.
    ///
    /// The batch's rules are today's:
    /// - continuations (``MainWorkScheduler/postContinuation(_:owner:file:line:_:)``) go first, in the order they were
    ///   posted, and never in the frame they were posted in: the continuation queue's fence sits after the ones posted
    ///   in an earlier frame (moved at the first continuation of each frame, removed at the first batch of a later one);
    /// - then posts, FIFO, only the ones posted before the batch began (an enqueue order up to its horizon);
    /// - the first task was admitted by the caller (``MainFrameBudget/mayRun(_:)``), each later one asks again.
    ///
    /// ```swift
    /// let queue = ClassQueue(.visible, on: mainWork)
    /// queue.post(owner: owner, post: post) { apply(patch) }
    /// _ = queue.drain(limit: queue.count)   // a turn's drain, after mayRun(.visible) said yes
    /// ```
    @MainActor
    final class ClassQueue {
        /// The class's place in the scheduler's order.
        let workClass: MainWorkClass
        private let budget: MainFrameBudget
        private let selector: MainTaskSelector
        private let posts: MainSequenceQueue
        private let continuations: MainSequenceQueue
        /// The frame (``MainFrameBudget/frameSerial``) whose continuations the fence holds.
        private var continuationFrame: UInt64 = 0
        private let client: FrameClient

        /// Lets the client's tick reach the queue before `self` exists (the client is built in init).
        @MainActor private final class Target {
            weak var queue: ClassQueue?
        }

        /// - Parameters:
        ///   - workClass: The class.
        ///   - work: The scheduler: its budget, selector and frames (the queue holds none of the scheduler itself).
        init(_ workClass: BudgetedWorkClass, on work: MainWorkScheduler) {
            self.workClass = workClass.workClass
            budget = work.budget
            selector = work.selector
            let type = Self.queueType(workClass)
            let owner = work.budget.board.owner("MainWork.\(workClass.workClass)")
            posts = work.selector.queue(type, owner: owner)
            continuations = work.selector.queue(type, owner: owner)
            let target = Target()
            // frame-client: the class's posted main-actor work in its budget each frame while work is left
            client = FrameClient(owner: "MainWork.\(workClass.workClass)", budgeted: workClass, on: work) { _, _ in
                target.queue?.drain() ?? false
            }
            target.queue = self
        }

        /// Tasks queued and not run yet, continuations held for a later frame included.
        var count: Int { posts.pendingCount + continuations.pendingCount }

        /// Queues `body` as `owner` (`post`: its site, enqueue time and node state for the board's ledger; nil: the
        /// task names its post when it runs one), without waking the frame: the scheduler runs it on the next turn or
        /// calls ``activate()``.
        func post(owner: MainTaskOwner, post: MainTaskPost?, _ body: @escaping @MainActor () -> Void) {
            posts.post(site: post?.site ?? Self.unnamedSite, owner: owner, posted: post, body)
        }

        /// Queues `body` ahead of every post, after the continuations queued before it, and ticks on the next frame.
        /// It waits for a later frame: the rest of a task that yielded never runs in the frame it yielded in.
        func postContinuation(owner: MainTaskOwner, post: MainTaskPost?, _ body: @escaping @MainActor () -> Void) {
            if !continuations.hasFence || continuationFrame != budget.frameSerial {
                // The ones posted in an earlier frame may run; this frame's wait behind the fence.
                continuations.insertFence(.now)
                continuationFrame = budget.frameSerial
            }
            continuations.post(site: post?.site ?? Self.unnamedSite, owner: owner, posted: post, body)
            client.activate()
        }

        /// Ticks on the next frame while work is queued (no effect while ticking).
        func activate() {
            guard count > 0 else { return }
            client.activate()
        }

        /// Whether the queue ticks on frames now.
        var isActive: Bool { client.isActive }

        /// Runs at most `limit` tasks now, by the rules above (the caller checked ``MainFrameBudget/mayRun(_:)`` for
        /// the first one); true while work is left. No copy and no re-insert: a backlog of N costs O(N) over all its
        /// batches.
        func drain(limit: Int = .max) -> Bool { // perf-hot: 0.5ms frame-tick (each budgeted class's batch, every frame with work)
            let horizon = selector.lastOrder
            var ran = 0
            while ran < limit, let queue = next(postedUpTo: horizon) {
                if ran > 0, !budget.mayRun(workClass) { break }
                let task = selector.take(from: queue)
                budget.run(workClass, owner: task.owner, posted: task.posted) { task.run() }
                ran += 1
            }
            return count > 0
        }

        /// The queue the next task comes from: a continuation of an earlier frame, else a post made by `horizon`.
        private func next(postedUpTo horizon: UInt64) -> MainSequenceQueue? {
            if continuations.hasFence, continuationFrame != budget.frameSerial { continuations.removeFence() }
            if continuations.isRunnable { return continuations }
            return posts.hasRunnableTask(postedUpTo: horizon) ? posts : nil
        }

        /// The site of a task whose post names none (it names its post when it runs, a node queue's pump).
        private static let unnamedSite = MainPostSite(file: #fileID, line: #line)

        /// The sequence manager's queue type of `workClass`.
        private static func queueType(_ workClass: BudgetedWorkClass) -> MainQueueType {
            switch workClass {
            case .userBlocking: .userBlocking
            case .visible: .visible
            case .automation: .automation
            case .background: .background
            }
        }
    }
}
