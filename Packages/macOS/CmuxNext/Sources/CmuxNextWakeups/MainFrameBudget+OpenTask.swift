extension MainFrameBudget {
    /// One task that started and has not returned.
    struct OpenTask {
        var workClass: MainWorkClass
        var owner: MainTaskOwner
        var sequence: UInt32
        var start: UInt64
        var budgetNanos: UInt64
        /// Where, when and in which node state it was posted (nil: run without a post).
        var post: MainTaskPost?
        /// It ran none of its posted work (``MainFrameBudget/noteRanNothing()``): not in the ledger.
        var ranNothing = false
        /// Time spent in tasks nested in this one.
        var childNanos: UInt64 = 0
        /// This one is a batch, not a request (``MainFrameBudget/markRunningTaskAsBatch()``, or a
        /// task of its class ran inside it): the typing burst does not count it.
        var isBatch = false
        /// Time it waited in nested run loops it ran (a menu, a modal panel), not its own.
        var parkedNanos: UInt64 = 0
        /// Since when it waits in one (nil: it runs).
        var parkedSince: UInt64?
        /// The nested run loops it waits in now.
        var parks = 0
        /// An idle task's idle deadline (``MainFrameBudget/noteIdleTask(postedFrom:deadlineNanos:)``; 0: none).
        var idleDeadlineNanos: UInt64 = 0
        /// Its own time at its last ``MainFrameBudget/shouldYield()``: the chunk since then is the next one's estimate.
        var ownAtYieldCheck: UInt64 = 0
        /// When its hang scope ends (``MainTaskBoard/hangScopeEnd(_:startNanos:idleDeadlineNanos:)``), on its own time as
        /// ``ownNanos(at:)``: its nested tasks and loops move it out, so a nested task's hang is not this one's too.
        var hangAtNanos: UInt64 { MainTaskBoard.hangScopeEnd(workClass, startNanos: start, idleDeadlineNanos: idleDeadlineNanos) &+ childNanos &+ parkedNanos }

        /// Its own time until `now`: less its nested tasks and the nested loops it waited in.
        func ownNanos(at now: UInt64) -> UInt64 {
            let elapsed = now &- start
            let parked = parkedNanos &+ (parkedSince.map { now &- $0 } ?? 0)
            let other = childNanos &+ parked
            return elapsed > other ? elapsed - other : 0
        }
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
}
