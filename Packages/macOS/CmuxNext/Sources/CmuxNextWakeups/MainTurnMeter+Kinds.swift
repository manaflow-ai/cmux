extension MainTurnMeter {
    /// What a turn ran for the budgeted scheduler: its display tick.
    public enum TurnKind: UInt8, Sendable {
        /// The budgeted scheduler's display tick (``MainFrameBudget/beginFrame(timestamp:targetTimestamp:refreshInterval:ranAt:)``).
        case tick = 1
    }

    // MARK: Reading

    /// A copy of the counters; ``Snapshot/longestUnattributed`` sorts the top turns off the main thread.
    public func snapshot() -> Snapshot {
        counters
    }

    /// Clears the counters (`debug.main_budget reset`); the turn in progress is kept.
    public func reset() {
        counters = Snapshot()
    }

    // MARK: Turn kinds

    /// Marks the turn in progress as `kind`: its end is counted in that kind's histogram too.
    // perf-hot: 100ns main-turn (every tick and budget turn)
    public func noteTurn(_ kind: TurnKind) {
        turnKinds |= kind.rawValue
    }

    /// Counts the turn that just ended in the histograms of its kinds; a tick turn that ran a budgeted
    /// task is counted apart.
    func recordKinds(turnNanos: UInt64) {
        let bucket = Snapshot.bucket(turnNanos)
        if turnKinds & TurnKind.tick.rawValue != 0 {
            counters.tickTurns.record(turnNanos, bucket: bucket)
            if ranBudgetedTask { counters.tickTurnsWithBudgetedTasks += 1 }
        }
    }
}
