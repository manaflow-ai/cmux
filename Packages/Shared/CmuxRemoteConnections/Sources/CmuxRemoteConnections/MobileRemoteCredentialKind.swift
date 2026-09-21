/// Kind of secret referenced by a connection profile.
public enum MobileRemoteCredentialKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// A saved SSH password.
    case password
    /// An imported or generated software private key.
    case privateKey = "private_key"
    /// A saved passphrase for an encrypted imported key.
    case privateKeyPassphrase = "private_key_passphrase"
}
