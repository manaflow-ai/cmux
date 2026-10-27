extension MainTaskBoard {
    /// What ``endSpan(_:nowNanos:)`` needs: the span itself and the work it covered.
    public struct SpanToken: Sendable {
        let packed: UInt64
        let startNanos: UInt64
        let budgetNanos: UInt64
        let previous: Published
    }

    /// The work the board names, as a span or a budget task that starts over it read it (``published``): what
    /// the board names again when that span or task ends, as Chrome's `TaskAnnotator` puts back the outer
    /// task's `PendingTask` when a nested one returns (`base/task/common/task_annotator.cc`).
    struct Published: Sendable {
        /// `class << 56 | owner << 32 | sequence`; 0: no work.
        let packed: UInt64
        let startNanos: UInt64
        let budgetNanos: UInt64
        /// When its hang scope ends.
        let hangAtNanos: UInt64

        /// The same work with its hang scope ending at `hangAt` (moved out by the time work over it ran).
        func endingAt(_ hangAt: UInt64) -> Published {
            Published(packed: packed, startNanos: startNanos, budgetNanos: budgetNanos, hangAtNanos: hangAt)
        }
    }

    /// The action span the board names now, which a budget task starting now inside `outer` (the budget's innermost
    /// open task) runs over: nil when the board names no work or `outer` (a task nested in `outer` publishes it
    /// again at its end). Main thread.
    func spanCovered(outer: MainFrameBudgetOpenTask?) -> Published? {
        let work = published
        guard work.packed != 0 else { return nil }
        if let outer, outer.parkedSince == nil, outer.packed == work.packed { return nil }
        return work
    }

    /// The packed identity the board publishes for a task or a span.
    static func pack(_ workClass: MainWorkClass, owner: UInt32, sequence: UInt32) -> UInt64 {
        UInt64(UInt8(workClass.rawValue)) << 56 | UInt64(owner & 0x00FF_FFFF) << 32 | UInt64(sequence)
    }
}
