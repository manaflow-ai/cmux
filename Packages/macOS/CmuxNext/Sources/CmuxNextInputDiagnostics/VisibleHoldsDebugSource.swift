public import CmuxNextWakeups

/// `debug.input` section `holds` from the app's ``VisibleHolds`` ledger: one row per hold owner (a pane's paint
/// hold, a window's workspace paint hold), with its limit, how many holds ended each way and the longest. Read off
/// the main thread: the ledger is behind its own lock.
///
/// ```swift
/// VisibleHoldsDebugSource(holds: services.mainDeadlines.holds)
/// ```
public nonisolated struct VisibleHoldsDebugSource: DebugInputSource {
    private let holds: VisibleHolds

    /// - Parameter holds: The ledger the app's holds record into.
    public init(holds: VisibleHolds) {
        self.holds = holds
    }

    public var section: DebugInputSection { .holds }

    public func read() async -> [VisibleHolds.Row] {
        holds.snapshot
    }

    public func reset() async {
        holds.reset()
    }
}
