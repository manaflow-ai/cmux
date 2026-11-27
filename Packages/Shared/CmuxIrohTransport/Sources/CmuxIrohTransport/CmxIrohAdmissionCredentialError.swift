/// Validation failures for Iroh admission credentials.
public enum CmxIrohAdmissionCredentialError: Error, Equatable, Sendable {
    /// A compact JWS is missing, malformed, or exceeds its wire limit.
    case invalidSignedToken

    /// The offline proof must contain exactly 32 bytes.
    case invalidOfflineProofLength(Int)
}
