public import CryptoKit
public import Foundation

/// A device membership entry trusted by an authenticated vault manifest.
///
/// Public keys are metadata. They authorize signed revisions only after the
/// caller has authenticated this membership and checked its vault and epoch.
public struct MobileRemoteVaultMember: Codable, Equatable, Sendable {
    /// Stable device identity.
    public let deviceID: UUID
    /// Authorization level for encrypted-record mutations.
    public let role: MobileRemoteVaultMemberRole
    /// Ed25519 public key raw representation.
    public let signingPublicKey: Data
    /// Key epoch in which this device was admitted.
    public let keyEpoch: Int64
    /// Whether this device is denied future writes.
    public let revoked: Bool

    /// Creates a bounded member entry.
    public init(
        deviceID: UUID,
        role: MobileRemoteVaultMemberRole,
        signingPublicKey: Data,
        keyEpoch: Int64,
        revoked: Bool = false
    ) throws {
        guard signingPublicKey.count == 32, keyEpoch > 0,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)) != nil else {
            throw MobileRemoteVaultMergeError.invalidMember
        }
        self.deviceID = deviceID
        self.role = role
        self.signingPublicKey = signingPublicKey
        self.keyEpoch = keyEpoch
        self.revoked = revoked
    }

    /// Resolves the trusted CryptoKit signing key.
    public func signingKey() throws -> Curve25519.Signing.PublicKey {
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        } catch {
            throw MobileRemoteVaultMergeError.invalidMember
        }
    }
}

/// Roles recognized by the encrypted vault writer policy.
public enum MobileRemoteVaultMemberRole: String, Codable, CaseIterable, Sendable {
    /// May create and update records.
    case owner
    /// May create and update records.
    case editor
    /// May decrypt records but cannot manufacture mutations.
    case viewer
    /// May recover a team vault through a separate recovery operation.
    case recovery
}
