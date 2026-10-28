/// One task of ``MainFrameBudget`` that started and has not returned (`MainFrameBudget.OpenTask`).
struct MainFrameBudgetOpenTask {
    var workClass: MainWorkClass
    var owner: MainTaskOwner
    var sequence: UInt32
    var start: UInt64
    var budgetNanos: UInt64
    /// Where, when and in which node state it was posted (nil: run without a post).
    var post: MainTaskPost?
    /// It runs inline, where its callback was delivered (``MainFrameBudget/runInline(_:owner:posted:_:)``): the
    /// scheduler did not pick it, so it takes no turn of its class's pacing.
    var isInline = false
    /// The action span the board named when it started (``MainTaskBoard/beginSpan(_:owner:budgetNanos:startNanos:)``),
    /// named again when it returns; nil when it started over no work or over the task it nests in.
    var covers: MainTaskBoard.Published?
    /// It ran none of its posted work (``MainFrameBudget/noteRanNothing()``): not in the ledger.
    var ranNothing = false
    /// Time spent in tasks nested in this one.
    var childNanos: UInt64 = 0
    /// The part of ``childNanos`` spent over an action span inside this one: the span's time moves this one's
    /// hang scope already (``MainTaskBoard/endSpan(_:nowNanos:)``).
    var spanChildNanos: UInt64 = 0
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
    var hangAtNanos: UInt64 {
        MainTaskBoard.hangScopeEnd(workClass, startNanos: start, idleDeadlineNanos: idleDeadlineNanos)
            &+ childNanos &- spanChildNanos &+ parkedNanos
    }

    /// The board identity it publishes.
    var packed: UInt64 { MainTaskBoard.pack(workClass, owner: owner.index, sequence: sequence) }

    /// A task nested in this one ran for `elapsed`; `overSpan`: over an action span inside this one.
    mutating func addChild(_ elapsed: UInt64, overSpan: Bool) {
        childNanos &+= elapsed
        if overSpan { spanChildNanos &+= elapsed }
    }

    /// Its own time until `now`: less its nested tasks and the nested loops it waited in.
    func ownNanos(at now: UInt64) -> UInt64 {
        let elapsed = now &- start
        let parked = parkedNanos &+ (parkedSince.map { now &- $0 } ?? 0)
        let other = childNanos &+ parked
        return elapsed > other ? elapsed - other : 0
    }
}
