public import CryptoKit
public import Foundation

/// Membership authenticated from an independently approved genesis and signed updates.
///
/// Only the verifier constructs this value. It is deliberately not Codable:
/// loading stored JSON must repeat verification against trusted local state.
/// Persist the accepted digest atomically with vault data before using an update.
public struct MobileRemoteTrustedVaultManifest: Sendable {
    /// Validated policy whose authority was checked by the verifier.
    public let manifest: MobileRemoteVaultManifest

    init(verified manifest: MobileRemoteVaultManifest) { self.manifest = manifest }

    /// Opens a current-epoch device envelope after checking both parties' authority.
    ///
    /// Organization recovery requires a separate audited recovery operation and
    /// cannot enter through this ordinary device-enrollment path.
    /// - Parameters:
    ///   - envelope: Received signed envelope, not trusted on receipt.
    ///   - recipientAccountID: Account established by the live cmux authentication gate.
    ///   - recipientDeviceID: This device's stable, locally stored identity.
    ///   - recipientEncryptionKey: This device's unlocked X25519 private key.
    /// - Returns: The 32-byte vault key for this manifest's epoch.
    /// - Throws: An authorization error or envelope signature/decryption failure.
    public func openDeviceKeyEnvelope(
        _ envelope: MobileRemoteVaultKeyEnvelope,
        recipientAccountID: String,
        recipientDeviceID: UUID,
        recipientEncryptionKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        guard envelope.accountID == manifest.accountID,
              envelope.vaultID == manifest.vaultID,
              envelope.keyEpoch == manifest.keyEpoch,
              let sender = manifest.participants.first(where: { $0.member.deviceID == envelope.senderDeviceID }),
              !sender.member.revoked, sender.member.role == .owner,
              let recipient = manifest.participants.first(where: { $0.member.deviceID == recipientDeviceID }),
              !recipient.member.revoked, recipient.member.role != .recovery,
              recipient.accountID == recipientAccountID,
              recipient.encryptionPublicKey == recipientEncryptionKey.publicKey.rawRepresentation else {
            throw MobileRemoteVaultManifestError.envelopeNotAuthorized
        }
        return try envelope.open(
            recipientDeviceID: recipientDeviceID,
            recipientEncryptionKey: recipientEncryptionKey,
            trustedSenderSigningKey: sender.member.signingKey()
        )
    }
}
