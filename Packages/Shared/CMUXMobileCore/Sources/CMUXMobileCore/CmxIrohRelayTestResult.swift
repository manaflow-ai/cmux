/// Non-secret result of probing a configured custom relay.
public enum CmxIrohRelayTestResult: Equatable, Sendable {
    /// The relay accepted a protocol connection.
    case reachable(latencyMilliseconds: Int?)

    /// The relay could not be reached or rejected the configured credential.
    case failed

    /// The relay definition or its required device credential is incomplete.
    case incomplete
}
