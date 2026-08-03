/// Selects the ownership boundary for a native surface free.
enum TerminalSurfaceRuntimeTeardownExecutionLane: Sendable {
    /// Uses the bounded, failure-isolated close worker pool.
    case boundedClose

    /// Gives an explicitly owned hibernation join an independent bounded slot.
    case isolatedHibernation
}
