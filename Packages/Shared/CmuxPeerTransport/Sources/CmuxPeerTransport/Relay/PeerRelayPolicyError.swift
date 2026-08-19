/// Validation failures for signed managed-relay policy handling.
///
/// Wire-compatible port of the legacy relay-policy error taxonomy; every
/// case fails closed to direct-only connectivity, never to unverified relays.
public enum PeerRelayPolicyError: Error, Equatable, Sendable {
    /// The compact JWS does not have the required three canonical segments.
    case invalidToken

    /// The JWS header is malformed or does not declare the relay-policy type.
    case invalidHeader

    /// The pinned relay-policy verification keys are malformed or ambiguous.
    case invalidTrustRoot

    /// The JWS key identifier is not present in the pinned trust root.
    case unknownKeyID

    /// The Ed25519 signature does not authenticate the policy payload.
    case invalidSignature

    /// The policy claims or relay descriptors violate the bounded schema.
    case invalidClaims

    /// The policy is not valid yet at the supplied verification time.
    case notYetValid

    /// The policy has reached its signed expiry.
    case expired

    /// The policy requires a relay protocol this client does not implement.
    case unsupportedRelayProtocol

    /// A valid policy is older than the highest policy sequence already installed.
    case rollback
}
