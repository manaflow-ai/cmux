public enum IrxEndpointError: Error, Sendable {
    case noUsableRelayCredential
    case endpointClosed
    case bindFailed(String)
    case noDirectAddress
}
