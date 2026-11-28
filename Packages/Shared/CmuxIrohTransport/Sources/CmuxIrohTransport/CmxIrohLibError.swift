/// Validation failures at the generated Iroh Swift binding boundary.
public enum CmxIrohLibError: Error, Equatable, Sendable {
    case invalidEndpointIdentity
    case remoteIdentityMismatch
    case unmanagedRelayURL(String)
    case expiredRelayCredential(String)
    case unsupportedRelayIdentifier
    case unexpectedALPN
    case invalidReceiveLimit(Int)
}
