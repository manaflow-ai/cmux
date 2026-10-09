/// Why a link key certificate was refused by the local verifier.
public enum LinkCertificateError: Error, Hashable, Sendable {
    case badKey
    case badSignature
    case lifetimeTooLong
    case expired
    case notYetValid
    case wrongPurpose
    case wrongInstall
    case wrongUser
}
