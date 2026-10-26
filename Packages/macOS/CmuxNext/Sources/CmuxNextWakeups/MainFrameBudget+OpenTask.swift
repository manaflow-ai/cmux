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
        /// Time spent in tasks nested in this one.
        var childNanos: UInt64 = 0
        /// This one is a batch, not a request (``MainFrameBudget/markRunningTaskAsBatch()``, or a
        /// task of its class ran inside it): the typing burst does not count it.
        var isBatch = false
    }
}
