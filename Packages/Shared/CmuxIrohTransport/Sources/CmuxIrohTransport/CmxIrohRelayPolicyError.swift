/// Validation failures for signed managed-relay policy and local relay selection.
public enum CmxIrohRelayPolicyError: Error, Equatable, Sendable {
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

    /// The local managed-relay selection is empty or references an unknown relay.
    case invalidSelection

    /// A valid policy is older than the highest policy sequence already installed.
    case rollback
}
