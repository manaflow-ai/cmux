import Foundation

/// A secret's metadata. It never carries the value; the only value-derived field is
/// ``fingerprint``, a keyed hash that cannot be reversed or compared across vaults.
public struct CloudSecretRecord: Hashable, Codable, Sendable {
    public let name: String
    public let scope: CloudSecretScope
    /// First 8 hex characters of HMAC-SHA256(vault key, value).
    public let fingerprint: String
    public let createdAt: Date
    public let updatedAt: Date
    public let source: CloudSecretSource

    public init(
        name: String,
        scope: CloudSecretScope,
        fingerprint: String,
        createdAt: Date,
        updatedAt: Date,
        source: CloudSecretSource
    ) {
        self.name = name
        self.scope = scope
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
    }
}
