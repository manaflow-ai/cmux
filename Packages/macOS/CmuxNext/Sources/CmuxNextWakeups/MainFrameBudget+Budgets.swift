extension MainFrameBudget {
    /// `duration` in whole nanoseconds (negative durations count as zero). Pure arithmetic: callable
    /// off the main actor (``FrameBudgets/passTargetNanos(intervalNanos:renderNanos:)``).
    public nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: seconds) &* 1_000_000_000 &+ UInt64(clamping: attoseconds / 1_000_000_000)
    }

    /// Per-frame budgets of the budgeted classes (``FrameBudgets``: the 60 Hz split, its refresh
    /// scaling and the pass targets of both batch placements).
    public typealias Budgets = FrameBudgets

    /// The after-commit placement's budget turn begins (the ``MainWorkScheduler``'s turn after the
    /// tick's commit): the turn meter counts the turn as a budget turn.
    public func beginBudgetTurn() {
        turns.noteTurn(.budget)
    }

    /// The budget turn's work ended: counted in ``budgetTurnStats``, late when it ended past the
    /// frame's deadline (the next vsync less the commit estimate).
    public func endBudgetTurn() {
        budgetTurnStats.noteEnded(at: uptimeNanos(), deadline: deadline)
    }
}
