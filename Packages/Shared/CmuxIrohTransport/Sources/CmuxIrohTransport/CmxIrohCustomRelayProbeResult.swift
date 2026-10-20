/// Redacted outcome of an isolated custom relay reachability probe.
public enum CmxIrohCustomRelayProbeResult: Equatable, Sendable {
    /// The temporary Iroh endpoint selected this exact custom relay.
    case reachable(relayURL: String)

    /// The profile was not a usable custom relay override.
    case invalidProfile

    /// The temporary endpoint could not be created.
    case bindFailed

    /// The endpoint closed before advertising an allowed custom relay.
    case endpointClosed

    /// No allowed custom relay became reachable before the bounded deadline.
    case timedOut
}
