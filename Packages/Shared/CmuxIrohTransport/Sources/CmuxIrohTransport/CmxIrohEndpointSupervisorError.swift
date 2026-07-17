/// Lifecycle failures surfaced by ``CmxIrohEndpointSupervisor``.
public enum CmxIrohEndpointSupervisorError: Error, Equatable, Sendable {
    /// No active endpoint is available for a dial or accept operation.
    case inactive

    /// A newer lifecycle transition invalidated an in-flight bind result.
    case superseded
}
