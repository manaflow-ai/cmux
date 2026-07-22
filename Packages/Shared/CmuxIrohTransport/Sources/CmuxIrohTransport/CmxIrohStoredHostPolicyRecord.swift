import Foundation

/// Versioned Keychain envelope for one active account's offline host policy.
struct CmxIrohStoredHostPolicyRecord: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let scopeDigest: String
    let policy: CmxIrohCachedHostPolicy

    init(scopeDigest: String, policy: CmxIrohCachedHostPolicy) {
        version = Self.currentVersion
        self.scopeDigest = scopeDigest
        self.policy = policy
    }
}
