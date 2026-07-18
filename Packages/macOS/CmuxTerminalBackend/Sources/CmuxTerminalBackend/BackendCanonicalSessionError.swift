/// Fail-closed canonical-session lifecycle errors.
public enum BackendCanonicalSessionError: Error, Equatable, Sendable {
    case alreadyConnected
    case notConnected
    case unexpectedSession(expected: String, actual: String)
    case unexpectedAuthority(expected: BackendAuthority, actual: BackendAuthority)
    case unexpectedProcessID(expected: UInt32, actual: UInt32)
    case unexpectedPeerIdentity(expected: BackendPeerIdentity, actual: BackendPeerIdentity)
    case snapshotAuthorityMismatch(expected: BackendAuthority, actual: BackendAuthority)
    case subscriptionAuthorityMismatch(expected: BackendAuthority, actual: BackendAuthority)
    case subscriptionCursorMismatch(expected: UInt64, actual: UInt64)
    case resnapshotRequired(TopologyResnapshotReason)
    case topologyStreamFailed(String)
}
