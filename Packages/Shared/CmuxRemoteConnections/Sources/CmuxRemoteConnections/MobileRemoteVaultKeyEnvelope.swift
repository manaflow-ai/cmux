public import CryptoKit
public import Foundation

/// A signed, recipient-bound envelope for transferring one vault epoch key.
///
/// The server may store or relay this envelope but cannot decrypt it or replace
/// its recipient without invalidating the sender signature. Enrollment still
/// requires an authenticated approval flow and membership check outside this
/// value type. The decrypted key is returned only to the caller.
public struct MobileRemoteVaultKeyEnvelope: Codable, Equatable, Sendable {
    /// Envelope format version.
    public static let currentVersion = 1
    /// Required vault-key size.
    public static let vaultKeyBytes = 32
    /// X25519 public-key size.
    public static let publicKeyBytes = 32
    /// Ed25519 signature size.
    public static let signatureBytes = 64

    /// Wire format version.
    public let version: Int
    /// Account owning the vault.
    public let accountID: String
    /// Stable vault identity.
    public let vaultID: UUID
    /// Key epoch being transferred.
    public let keyEpoch: Int64
    /// Approved sender device identity.
    public let senderDeviceID: UUID
    /// Recipient device or organization recovery identity.
    public let recipientDeviceID: UUID
    /// Ephemeral X25519 public key used only for this envelope.
    public let ephemeralPublicKey: Data
    /// AES-GCM nonce.
    public let nonce: Data
    /// Ciphertext and authentication tag, without the nonce.
    public let ciphertext: Data
    /// Sender Ed25519 signature over all other fields.
    public let signature: Data

    /// Creates a validated envelope from transport fields.
    public init(
        accountID: String,
        vaultID: UUID,
        keyEpoch: Int64,
        senderDeviceID: UUID,
        recipientDeviceID: UUID,
        ephemeralPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        signature: Data
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              keyEpoch > 0,
              ephemeralPublicKey.count == Self.publicKeyBytes,
              nonce.count == 12,
              ciphertext.count >= Self.vaultKeyBytes + 16,
              signature.count == Self.signatureBytes else {
            throw MobileRemoteVaultKeyEnvelopeError.invalidEnvelope
        }
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)) != nil else {
            throw MobileRemoteVaultKeyEnvelopeError.invalidEnvelope
        }
        self.version = Self.currentVersion
        self.accountID = accountID
        self.vaultID = vaultID
        self.keyEpoch = keyEpoch
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }

    /// Creates a fresh envelope for one approved recipient.
    ///
    /// - Parameters:
    ///   - vaultKey: 256-bit key for the stated epoch.
    ///   - accountID: Expected vault owner account.
    ///   - vaultID: Stable vault identity.
    ///   - keyEpoch: Positive key generation.
    ///   - senderDeviceID: Existing approved device identity.
    ///   - senderSigningKey: Existing device signing key.
    ///   - recipientDeviceID: New device or organization recovery identity.
    ///   - recipientEncryptionKey: Recipient X25519 public key from authenticated enrollment.
    /// - Throws: Validation or CryptoKit failures.
    public static func seal(
        vaultKey: Data,
        accountID: String,
        vaultID: UUID,
        keyEpoch: Int64,
        senderDeviceID: UUID,
        senderSigningKey: Curve25519.Signing.PrivateKey,
        recipientDeviceID: UUID,
        recipientEncryptionKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Self {
        guard vaultKey.count == Self.vaultKeyBytes, keyEpoch > 0 else {
            throw MobileRemoteVaultKeyEnvelopeError.invalidEnvelope
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let aad = try associatedData(
            accountID: accountID, vaultID: vaultID, keyEpoch: keyEpoch,
            senderDeviceID: senderDeviceID, recipientDeviceID: recipientDeviceID,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation
        )
        let key = try derivedKey(
            ephemeral.sharedSecretFromKeyAgreement(with: recipientEncryptionKey),
            associatedData: aad
        )
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(vaultKey, using: key, nonce: nonce, authenticating: aad)
        let envelope = try Self(
            accountID: accountID, vaultID: vaultID, keyEpoch: keyEpoch,
            senderDeviceID: senderDeviceID, recipientDeviceID: recipientDeviceID,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: Data(nonce), ciphertext: sealed.ciphertext + sealed.tag,
            signature: Data(repeating: 0, count: Self.signatureBytes)
        )
        let signature = try senderSigningKey.signature(for: envelope.signingData())
        return try Self(
            accountID: envelope.accountID, vaultID: envelope.vaultID,
            keyEpoch: envelope.keyEpoch, senderDeviceID: envelope.senderDeviceID,
            recipientDeviceID: envelope.recipientDeviceID,
            ephemeralPublicKey: envelope.ephemeralPublicKey, nonce: envelope.nonce,
            ciphertext: envelope.ciphertext, signature: Data(signature)
        )
    }

    /// Opens the envelope only for the expected recipient and trusted sender.
    ///
    /// The caller must independently establish that the sender is an approved
    /// member and that this epoch is current or explicitly recoverable.
    public func open(
        recipientDeviceID: UUID,
        recipientEncryptionKey: Curve25519.KeyAgreement.PrivateKey,
        trustedSenderSigningKey: Curve25519.Signing.PublicKey
    ) throws -> Data {
        guard self.recipientDeviceID == recipientDeviceID,
              version == Self.currentVersion,
              trustedSenderSigningKey.isValidSignature(signature, for: signingData()) else {
            throw MobileRemoteVaultKeyEnvelopeError.signatureInvalid
        }
        let aad = try Self.associatedData(
            accountID: accountID, vaultID: vaultID, keyEpoch: keyEpoch,
            senderDeviceID: senderDeviceID, recipientDeviceID: self.recipientDeviceID,
            ephemeralPublicKey: ephemeralPublicKey
        )
        do {
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)
            let key = try Self.derivedKey(
                recipientEncryptionKey.sharedSecretFromKeyAgreement(with: ephemeral),
                associatedData: aad
            )
            let combined = nonce + ciphertext
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let opened = try AES.GCM.open(sealed, using: key, authenticating: aad)
            guard opened.count == Self.vaultKeyBytes else {
                throw MobileRemoteVaultKeyEnvelopeError.decryptionFailed
            }
            return opened
        } catch let error as MobileRemoteVaultKeyEnvelopeError {
            throw error
        } catch {
            throw MobileRemoteVaultKeyEnvelopeError.decryptionFailed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, accountID, vaultID, keyEpoch, senderDeviceID
        case recipientDeviceID, ephemeralPublicKey, nonce, ciphertext, signature
    }

    /// Decodes with the same transport bounds as direct construction.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw MobileRemoteVaultKeyEnvelopeError.unsupportedVersion(version)
        }
        try self.init(
            accountID: values.decode(String.self, forKey: .accountID),
            vaultID: values.decode(UUID.self, forKey: .vaultID),
            keyEpoch: values.decode(Int64.self, forKey: .keyEpoch),
            senderDeviceID: values.decode(UUID.self, forKey: .senderDeviceID),
            recipientDeviceID: values.decode(UUID.self, forKey: .recipientDeviceID),
            ephemeralPublicKey: values.decode(Data.self, forKey: .ephemeralPublicKey),
            nonce: values.decode(Data.self, forKey: .nonce),
            ciphertext: values.decode(Data.self, forKey: .ciphertext),
            signature: values.decode(Data.self, forKey: .signature)
        )
    }

    private func signingData() -> Data {
        var data = Data("cmux.remote-vault.key-envelope.v1".utf8)
        Self.append(String(version), to: &data)
        Self.append(accountID, to: &data)
        Self.append(vaultID.uuidString.lowercased(), to: &data)
        Self.append(String(keyEpoch), to: &data)
        Self.append(senderDeviceID.uuidString.lowercased(), to: &data)
        Self.append(recipientDeviceID.uuidString.lowercased(), to: &data)
        Self.append(ephemeralPublicKey, to: &data)
        Self.append(nonce, to: &data)
        Self.append(ciphertext, to: &data)
        return data
    }

    private static func associatedData(
        accountID: String,
        vaultID: UUID,
        keyEpoch: Int64,
        senderDeviceID: UUID,
        recipientDeviceID: UUID,
        ephemeralPublicKey: Data
    ) throws -> Data {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              keyEpoch > 0,
              ephemeralPublicKey.count == Self.publicKeyBytes else {
            throw MobileRemoteVaultKeyEnvelopeError.invalidEnvelope
        }
        var data = Data("cmux.remote-vault.key-envelope.aad.v1".utf8)
        for value in [
            Data(accountID.utf8),
            Data(vaultID.uuidString.lowercased().utf8),
            Data(String(keyEpoch).utf8),
            Data(senderDeviceID.uuidString.lowercased().utf8),
            Data(recipientDeviceID.uuidString.lowercased().utf8),
            ephemeralPublicKey,
        ] {
            append(value, to: &data)
        }
        return data
    }

    private static func derivedKey(
        _ sharedSecret: SharedSecret,
        associatedData: Data
    ) throws -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("cmux.remote-vault.key-envelope.salt.v1".utf8),
            sharedInfo: associatedData,
            outputByteCount: 32
        )
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        var count = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

/// Failures from a signed recipient-bound vault-key envelope.
public enum MobileRemoteVaultKeyEnvelopeError: Error, Equatable, Sendable {
    /// Envelope fields are malformed or exceed bounded sizes.
    case invalidEnvelope
    /// The envelope version is not implemented.
    case unsupportedVersion(Int)
    /// The sender signature or recipient identity did not authenticate.
    case signatureInvalid
    /// The encrypted key could not be opened.
    case decryptionFailed
    /// The envelope was valid but did not contain a 256-bit key.
    case invalidKey
}
