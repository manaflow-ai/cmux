extension BackgroundWork {
    /// A ``task(_:shutdown:fileID:line:_:)`` task that has not finished, as ``shutdown()`` sees it.
    struct RegisteredTask {
        let shutdown: ShutdownBehavior
        /// Cancels the task; nil until the task exists (it is registered first, so shutdown cannot miss it).
        var cancel: (@Sendable () -> Void)?
        /// Shutdown came before ``cancel`` was set: the task is cancelled as soon as it is.
        var cancelRequested = false
    }

    /// Test seams between the steps of a ``task(_:shutdown:fileID:line:_:)`` start, so a test can put a shutdown
    /// in each window; ``none`` runs every step at once.
    struct TaskHooks: Sendable {
        /// Awaited first in the task's body, before it checks for shutdown and runs `op`.
        var beforeBody: @Sendable () async -> Void
        /// Called with the step that gives the registered task its cancel; the default calls it at once.
        var attach: @Sendable (_ attachNow: @escaping @Sendable () -> Void) -> Void

        static let none = TaskHooks(beforeBody: {}, attach: { $0() })
    }

    /// Starts `op` as a detached task at `priority` that ``shutdown()`` knows about: Chrome's
    /// `PostTask(FROM_HERE, {priority, shutdown_behavior}, task)` for async work
    /// (`base/task/thread_pool/task_tracker.cc`).
    ///
    /// Use it for async work that has no actor of its own (instead of `Task.detached`): it states its
    /// priority on purpose (plans/cmux-next/PATTERNS.md P14), and quit cancels it or waits for it by
    /// `shutdown`. Work that calls a blocking API belongs on a lane (``run(_:mayBlock:shutdown:fileID:line:_:)``),
    /// never in `op`: `op` runs on the cooperative pool or on its own actor.
    ///
    /// - ``ShutdownBehavior/skipOnShutdown``: shutdown cancels it (`op` sees `Task.isCancelled`; one that has
    ///   not started never runs `op`).
    /// - ``ShutdownBehavior/continueOnShutdown``: a started one runs on; shutdown does not wait for it. One that
    ///   has not started never runs `op`.
    /// - ``ShutdownBehavior/blockShutdown``: shutdown returns only after it finished. Only for one bounded
    ///   write (< 50 ms); Debug records one that runs longer than ``blockShutdownLimit``.
    ///
    /// After shutdown started, only a block-shutdown task runs; any other returns a task that throws
    /// `CancellationError` without running `op`. After ``shutdown()`` returned, a block-shutdown task is refused
    /// the same way (nothing would wait for it) and Debug records its site (``blockShutdownLatePosts``).
    ///
    /// ```swift
    /// let page = work.task(.userVisible) { try await client.fetch(url) }
    /// let text = try await page.value
    /// ```
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it; a higher-priority task that awaits the result raises
    ///     it (Swift's task escalation).
    ///   - shutdown: what ``shutdown()`` does with it; default ``ShutdownBehavior/skipOnShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown task (leave the default).
    ///   - line: the caller's `#line`.
    ///   - op: the async work. A closure with no global actor runs on the cooperative pool; one isolated to
    ///     an actor runs there.
    /// - Returns: the task; its value is what `op` returns, or what `op` throws, or `CancellationError`
    ///   when it was refused, or cancelled before `op` started.
    @discardableResult
    public func task<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                  fileID: StaticString = #fileID, line: UInt = #line,
                                  _ op: sending @escaping @isolated(any) () async throws -> T) -> Task<T, any Error> {
        let blocks = shutdown == .blockShutdown
        let site = CallSite(fileID: fileID, line: line)
        let id: UInt64? = state.withLock { state in
            guard blocks ? !state.drained : !state.closed else { return nil }
            let id = state.takeID()
            state.tasks[id] = RegisteredTask(shutdown: shutdown)
            if blocks { state.blocking += 1 }
            return id
        }
        guard let id else {
            if blocks { blockShutdownRefused(site) }
            return Task<T, any Error>.detached(priority: priority.taskPriority) { throw CancellationError() }
        }
        let hooks = taskHooks
        let task = Task<T, any Error>.detached(priority: priority.taskPriority) { [self] in
            await hooks.beforeBody()
            let start = blocks ? blockShutdownStarted() : nil
            defer { taskFinished(id, site: site, since: start) }
            // Not started when shutdown began: only a block-shutdown task runs (Chrome skips the others).
            if !blocks, state.withLock({ $0.closed }) { throw CancellationError() }
            try Task.checkCancellation()
            return try await op()
        }
        hooks.attach { [self] in self.attach(id, cancel: { task.cancel() }) }
        return task
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Fragments of the demangled names of ``task(_:shutdown:fileID:line:_:)`` and its generic specializations. The
    /// launch's global-job census (CmuxNextLaunch's `GlobalJobCensus`) names the caller past it for a
    /// task whose creating stack runs through it, and marks the task as started here. Such a task starts at once,
    /// outside the launch fence, so it is still a Q12 task. Nothing in this module calls it, so it keeps its own frame
    /// in every build.
    public static let ownTaskFrames = ["BackgroundWork.task<", "BackgroundWork.task("]
    #endif

    /// The ``task(_:shutdown:fileID:line:_:)`` tasks that have not finished.
    public var registeredTaskCount: Int {
        state.withLock { $0.tasks.count }
    }

    /// Gives registered task `id` its cancel; cancels at once when shutdown asked for it in between.
    private func attach(_ id: UInt64, cancel: @escaping @Sendable () -> Void) {
        let cancelNow = state.withLock { state -> Bool in
            // Absent: the task already finished.
            guard var entry = state.tasks[id] else { return false }
            entry.cancel = cancel
            state.tasks[id] = entry
            return entry.cancelRequested
        }
        if cancelNow { cancel() }
    }

    private func taskFinished(_ id: UInt64, site: CallSite, since start: UInt64?) {
        let blocked = state.withLock { $0.tasks.removeValue(forKey: id)?.shutdown == .blockShutdown }
        guard blocked else { return }
        blockShutdownEnded(site, since: start)
        blockItemFinished()
    }
}

extension BackgroundWork.DrainState {
    /// The cancels of every skip-on-shutdown task; one not yet attached is marked so it is cancelled
    /// when it is.
    mutating func skipTaskCancels() -> [@Sendable () -> Void] {
        var cancels: [@Sendable () -> Void] = []
        for (id, entry) in tasks where entry.shutdown == .skipOnShutdown {
            if let cancel = entry.cancel {
                cancels.append(cancel)
            } else {
                tasks[id]?.cancelRequested = true
            }
        }
        return cancels
    }
}
