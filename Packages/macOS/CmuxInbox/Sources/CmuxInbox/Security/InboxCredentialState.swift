import Foundation

/// Redacted credential availability for one connector account.
public enum InboxCredentialState: String, Codable, CaseIterable, Sendable, Hashable {
    /// No credential exists for the account.
    case missing
    /// A credential exists but its bytes are never exposed.
    case present
    /// The keychain item exists but cannot currently be read.
    case inaccessible
}
