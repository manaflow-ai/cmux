/// Fail-closed reasons for a backend-signed grant or attestation.
public enum CmxIrohGrantVerifierError: Error, Equatable, Sendable {
    case invalidKeySet
    case invalidToken
    case invalidHeader
    case unknownKeyID
    case invalidSignature
    case invalidClaims
    case expired
    case identityMismatch
    case accountMismatch
}
