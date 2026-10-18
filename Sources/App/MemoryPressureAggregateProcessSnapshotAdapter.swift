import CmuxMemoryPressure

/// Adapts the app-owned process census to the aggregate-memory package seam.
extension CmuxTopProcessSnapshot: MemoryPressureAggregateProcessSnapshot {
    /// Returns the captured process-tree closure for aggregate accounting.
    func aggregateExpandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        expandedPIDs(rootPIDs: rootPIDs)
    }

    /// Converts an app process record into the package's privacy-safe seam.
    func aggregateProcess(pid: Int) -> MemoryPressureAggregateProcessRecord? {
        guard let process = process(pid: pid) else { return nil }
        return MemoryPressureAggregateProcessRecord(
            pid: process.pid,
            memoryBytes: process.memoryBytes,
            hasReadableMemory: process.memorySource != .unavailable
        )
    }
}
