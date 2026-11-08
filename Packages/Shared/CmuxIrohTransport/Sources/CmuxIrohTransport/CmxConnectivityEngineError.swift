/// Lifecycle and peer-intent failures raised by connectivity v2.
public enum CmxConnectivityEngineError: Error, Equatable, Sendable {
    /// The process endpoint is not active.
    case inactive

    /// A concurrent lifecycle change superseded the operation.
    case superseded

    /// The request does not identify one admitted Iroh peer.
    case invalidPeerIntent

    /// The request targets a different peer than the selected session owner.
    case peerIntentMismatch
}
