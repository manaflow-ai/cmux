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

    /// Now on the budget's clock: the enqueue time of a post it will run.
    var nowNanos: UInt64 { uptimeNanos() }

    /// The running task is a batch that runs requests as tasks of their own (a control drain): the
    /// typing burst's one task per 100 ms counts those, so a drain that ran none takes no slot.
    public func markRunningTaskAsBatch() {
        if !open.isEmpty { open[open.count - 1].isBatch = true }
    }
}
