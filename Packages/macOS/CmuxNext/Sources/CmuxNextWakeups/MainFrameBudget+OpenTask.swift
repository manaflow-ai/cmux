extension MainFrameBudget {
    /// One task that started and has not returned.
    typealias OpenTask = MainFrameBudgetOpenTask

    /// Runs `body` now as a task of `workClass` for `owner` that the scheduler did not pick: a callback delivered on
    /// the main thread (``MainDelivery``) or a classed run-loop block (``MainRunLoopBlock``). The board names it, the
    /// ledger records it and its class is charged with its time, as ``run(_:owner:posted:_:)`` does. It cannot wait,
    /// so it takes no turn of its class's pacing: the typing burst's one task per interval and the class's first task
    /// of a frame stay with the work the scheduler posts, and a task it nests in stays a request, not a batch.
    ///
    /// - Parameters:
    ///   - workClass: The task's class.
    ///   - owner: Its owner, interned on this budget's ``board``.
    ///   - post: Where and when it was delivered.
    ///   - body: The task.
    public func runInline(_ workClass: MainWorkClass, owner: MainTaskOwner, posted post: MainTaskPost, _ body: () -> Void) {
        runTask(workClass, owner: owner, posted: post, inline: true, body)
    }

    /// `task` returned after `elapsed`: the board names the action span it ran over again, its hang scope moved out by
    /// the task's time (as ``MainTaskBoard/endSpan(_:nowNanos:)`` moves a covered task's), or else the outer task
    /// (not while that waits in a nested loop).
    func publishCovered(by task: OpenTask, elapsed: UInt64) {
        if let span = task.covers {
            board.publish(span.endingAt(span.hangAtNanos &+ elapsed))
        } else if let outer = open.last, outer.parkedSince == nil {
            publish(outer)
        }
    }

    /// Names `task` on the board again, as the running task.
    func publish(_ task: OpenTask) {
        board.begin(task.workClass, owner: task.owner.index, sequence: task.sequence, startNanos: task.start,
                    budgetNanos: task.budgetNanos, hangAtNanos: task.hangAtNanos, notify: false)
    }

    /// Whether a task runs now: one is open and not waiting in a nested run loop it ran.
    var taskRuns: Bool {
        guard let task = open.last else { return false }
        return task.parkedSince == nil
    }
}

extension MainFrameBudget {
    /// The running task runs work posted as `post` (a node queue's pump runs a task it held, a
    /// control drain runs a request it claimed): the board and the ledger take that post in place
    /// of the running task's.
    public func notePost(_ post: MainTaskPost) {
        if !open.isEmpty { open[open.count - 1].post = post }
        board.notePostedFrom(post.site)
    }

    /// The running task ran none of the work it was posted for (a node queue's pump found its node
    /// hidden, frozen or disabled, a control request expired before it ran): the ledger leaves it
    /// out, so a held task is recorded once, with its wait and node state, when it runs.
    public func noteRanNothing() {
        if !open.isEmpty { open[open.count - 1].ranNothing = true }
    }

    /// The running task is an idle task (``IdleScheduler``) posted at `site` whose idle period ends at `deadlineNanos`: the
    /// board names its site, and its hang scope runs one frame past that deadline instead of past its start.
    func noteIdleTask(postedFrom site: MainPostSite, deadlineNanos: UInt64) {
        board.notePostedFrom(site)
        guard !open.isEmpty else { return }
        open[open.count - 1].idleDeadlineNanos = deadlineNanos
        board.extendHangScope(to: open[open.count - 1].hangAtNanos)
    }

    /// Now on the budget's clock: the enqueue time of a post it will run.
    var nowNanos: UInt64 { uptimeNanos() }

    /// The running task is a batch that runs requests as tasks of their own (a control drain): the
    /// typing burst's one task per 100 ms counts those, so a drain that ran none takes no slot.
    public func markRunningTaskAsBatch() {
        if !open.isEmpty { open[open.count - 1].isBatch = true }
    }

    /// A nested run loop started or stopped running (``MainTurnMeter/nestedLoopRunning``). The task
    /// that ran it (a pump pass that runs a context menu, a menu action that runs a modal panel) waits
    /// while it runs: that time is not its own, the board names no task meanwhile, and the frame
    /// window rolls on an idle app as when no task is open. Tasks run inside the loop are charged as
    /// themselves; the task's work after the loop returns is its own again.
    func nestedLoop(running: Bool, at now: UInt64) {
        defer { board.nestedLoops(running: parkedBy.count, startedAt: running ? now : nil) } // invalidates hang scopes
        if running {
            guard let index = open.indices.last else { return parkedBy.append(nil) }
            parkedBy.append(open[index].sequence)
            if open[index].parks == 0 {
                open[index].parkedSince = now
                board.endParked()
            }
            open[index].parks += 1
            return
        }
        // None ran the loop, or the task already ended (an exception unwound past the loop's exit).
        guard let entry = parkedBy.popLast(), let sequence = entry,
              let index = open.lastIndex(where: { $0.sequence == sequence }) else { return }
        open[index].parks -= 1
        guard open[index].parks == 0, let since = open[index].parkedSince else { return }
        open[index].parkedNanos &+= now &- since
        open[index].parkedSince = nil
        if index == open.count - 1 { publish(open[index]) }
    }
}
