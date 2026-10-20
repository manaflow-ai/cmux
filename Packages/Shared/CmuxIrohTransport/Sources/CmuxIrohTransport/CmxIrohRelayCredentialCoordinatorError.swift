/// Relay credential scheduling failures owned by the app transport layer.
public enum CmxIrohRelayCredentialCoordinatorError: Error, Equatable, Sendable {
    case inactive
    case relayFleetMismatch
}
