/// Selects the ownership boundary for a native surface free.
enum TerminalSurfaceRuntimeTeardownExecutionLane: Sendable {
    /// Uses the bounded close/deinit pool without blocking later frees.
    case boundedClose

    /// Gives an explicitly owned hibernation join an independent bounded slot.
    case isolatedHibernation
}
