public import Foundation
import CryptoKit

/// An account-bound device and its signing and key-delivery authority.
public struct MobileRemoteVaultParticipant: Codable, Equatable, Sendable {
    /// Authenticated cmux account to which the device belongs.
    public let accountID: String
    /// Device signing identity, role, epoch, and revocation state.
    public let member: MobileRemoteVaultMember
    /// X25519 public key used to deliver vault keys to this device.
    public let encryptionPublicKey: Data

    /// Creates an entry for inclusion in an owner-signed manifest.
    /// - Parameters:
    ///   - accountID: Account independently verified during device approval.
    ///   - member: Device signing identity and access policy.
    ///   - encryptionPublicKey: Approved device's raw 32-byte X25519 public key.
    /// - Throws: An error if identifiers or public-key representations are invalid.
    public init(accountID: String, member: MobileRemoteVaultMember, encryptionPublicKey: Data) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              encryptionPublicKey.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryptionPublicKey)) != nil else {
            throw MobileRemoteVaultManifestError.invalidParticipant
        }
        // Reconstruct because older member decoders did not enforce init bounds.
        self.member = try MobileRemoteVaultMember(
            deviceID: member.deviceID, role: member.role,
            signingPublicKey: member.signingPublicKey, keyEpoch: member.keyEpoch,
            revoked: member.revoked
        )
        self.accountID = accountID
        self.encryptionPublicKey = encryptionPublicKey
    }

    private enum CodingKeys: String, CodingKey { case accountID, member, encryptionPublicKey }

    /// Decodes an entry with the same bounds as explicit construction.
    /// - Parameter decoder: Decoder for transport-bounded manifest content.
    /// - Throws: Decoding or participant validation errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: values.decode(String.self, forKey: .accountID),
            member: values.decode(MobileRemoteVaultMember.self, forKey: .member),
            encryptionPublicKey: values.decode(Data.self, forKey: .encryptionPublicKey)
        )
    }
}
