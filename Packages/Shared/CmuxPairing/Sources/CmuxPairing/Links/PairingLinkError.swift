/// Why a `pair` or `attach` link was refused (b6-pairing.md section 4.1).
public enum PairingLinkError: Error, Hashable, Sendable {
    /// Not a cmux pairing link at all.
    case notPairingLink
    /// A newer grammar: the app must be updated.
    case unsupportedVersion(String)
    case missingField(String)
    case invalidField(String)
    case expired
}
