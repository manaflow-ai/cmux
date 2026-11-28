/// The coarse lifecycle of a supervised Iroh endpoint.
public enum CmxIrohEndpointLifecycleState: Equatable, Sendable {
    /// The app does not currently want an endpoint bound.
    case inactive

    /// A new endpoint generation is binding.
    case starting

    /// The generation is bound and may accept or create connections.
    case active

    /// The most recent bind or recovery attempt failed.
    case failed
}
