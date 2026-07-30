/// Selects the ownership boundary for a native surface free.
enum TerminalSurfaceRuntimeTeardownExecutionLane: Sendable {
    /// Preserves ordering for close/deinit flows that can re-enter teardown.
    case serializedClose

    /// Gives an explicitly owned hibernation join an independent bounded slot.
    case isolatedHibernation
}
