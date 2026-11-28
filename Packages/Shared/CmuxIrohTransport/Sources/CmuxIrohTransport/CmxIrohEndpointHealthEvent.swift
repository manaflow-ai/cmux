/// A lifecycle signal emitted by an active Iroh endpoint generation.
public enum CmxIrohEndpointHealthEvent: Equatable, Sendable {
    /// Iroh completed its initial network discovery work.
    case online

    /// The local network changed and reachability should be republished.
    case networkChanged

    /// The endpoint driver stopped without an explicit lifecycle close.
    case closedUnexpectedly
}
