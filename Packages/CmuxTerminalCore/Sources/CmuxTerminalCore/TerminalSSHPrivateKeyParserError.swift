public import Foundation

/// An error produced while parsing an OpenSSH private key.
public enum TerminalSSHPrivateKeyParserError: LocalizedError, Equatable {
    /// The text is not a valid OpenSSH private key.
    case invalidFormat
    /// The key is encrypted, which is not supported.
    case encryptedKeysUnsupported
    /// The key uses an unsupported algorithm/type.
    case unsupportedKeyType
    /// The key material failed validation against its embedded public key.
    case invalidKeyMaterial

    /// A localized, user-facing description of the error.
    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(
                localized: "terminal.ssh.private_key_invalid",
                defaultValue: "The SSH private key is not a valid OpenSSH key."
            )
        case .encryptedKeysUnsupported:
            return String(
                localized: "terminal.ssh.private_key_encrypted_unsupported",
                defaultValue: "Encrypted SSH private keys are not supported yet."
            )
        case .unsupportedKeyType:
            return String(
                localized: "terminal.ssh.private_key_unsupported_type",
                defaultValue: "This SSH private key type is not supported yet."
            )
        case .invalidKeyMaterial:
            return String(
                localized: "terminal.ssh.private_key_invalid_material",
                defaultValue: "The SSH private key material is invalid."
            )
        }
    }
}
