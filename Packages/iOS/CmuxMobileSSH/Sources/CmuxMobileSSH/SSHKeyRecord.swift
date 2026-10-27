import Foundation

/// Metadata for one user key. The secret lives in the Keychain (imported keys)
/// or the Secure Enclave (generated keys) and never leaves the device.
public struct SSHKeyRecord: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// P-256 key created in the Secure Enclave; not exportable.
        case secureEnclave
        /// OpenSSH private key text imported by the user, stored in the Keychain.
        case imported
    }

    public var id: UUID
    public var label: String
    public var kind: Kind
    public var algorithm: String
    /// OpenSSH public key line, with the label as comment.
    public var publicKeyLine: String
    /// PRD D18: Face ID on each use, off by default.
    public var requiresBiometry: Bool
    public var createdAt: Date

    public var fingerprint: String {
        SSHHostKey(openSSHString: publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")).sha256Fingerprint
    }
}
