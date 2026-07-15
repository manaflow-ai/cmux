/// An observable state or reachability event from the endpoint supervisor.
public enum CmxIrohEndpointSupervisorEvent: Equatable, Sendable {
    /// The endpoint lifecycle snapshot changed.
    case snapshot(CmxIrohEndpointSnapshot)

    /// Iroh observed a local network change for the active generation.
    case networkChanged(runtimeGeneration: UInt64)

    /// An unexpectedly closed driver was replaced using the same secret key.
    case recovered(previousGeneration: UInt64, newGeneration: UInt64)
}
