import CmuxNextCompat

extension MemoryCoordinator {
    /// What every live consumer holds now, with the limit it has and the level, mode and budget
    /// the limits come from (Chrome's memory-infra dump, `base/trace_event/memory_dump_manager.h`).
    ///
    /// One pass over the consumers, O(consumers), on the main actor: no lock is held across
    /// consumers and no consumer on another actor is awaited (it reports the last value it sent).
    /// A consumer that cannot tell its size shows as unknown, never as 0.
    ///
    /// - Returns: The snapshot `debug.memory` serves.
    public func report() -> MemoryReport {
        MemoryReport(
            level: level,
            mode: mode,
            budget: budget,
            entries: consumers.liveEntries(),
            limit: { limit(for: $0) }
        )
    }
}
