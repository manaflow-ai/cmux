extension MainFrameBudget {
    /// `duration` in whole nanoseconds (negative durations count as zero). Pure arithmetic: callable
    /// off the main actor (``FrameBudgets/passTargetNanos(intervalNanos:renderNanos:)``).
    public nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: seconds) &* 1_000_000_000 &+ UInt64(clamping: attoseconds / 1_000_000_000)
    }

    /// Per-frame budgets of the budgeted classes (``FrameBudgets``).
    public typealias Budgets = FrameBudgets
}
