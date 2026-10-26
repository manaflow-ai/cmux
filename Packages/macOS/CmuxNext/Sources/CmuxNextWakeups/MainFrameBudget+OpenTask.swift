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

        /// Its own time until `now`: less its nested tasks and the nested loops it waited in.
        func ownNanos(at now: UInt64) -> UInt64 {
            let elapsed = now &- start
            let parked = parkedNanos &+ (parkedSince.map { now &- $0 } ?? 0)
            let other = childNanos &+ parked
            return elapsed > other ? elapsed - other : 0
        }
    }
}
