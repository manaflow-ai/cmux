public import CryptoKit
public import Foundation

/// Signed metadata for one encrypted vault record.
///
/// Verification proves possession of the specified signing key and binds the
/// exact ciphertext to the caller's expected context. Membership, write
/// permissions, organization scope, and freshness must be verified separately.
/// Replaying a previously valid signature is not prevented by this primitive.
public struct MobileRemoteVaultRevision: Codable, Equatable, Sendable {
    /// Signed metadata format version.
    public static let currentVersion = 1
    /// SHA-256 digest length required for the sealed record.
    public static let digestLength = 32

    /// Metadata format version.
    public let version: Int
    /// Account that owns the personal or team vault.
    public let accountID: String
    /// Stable vault identity.
    public let vaultID: UUID
    /// Stable record identity.
    public let recordID: UUID
    /// Payload domain authenticated by the record cipher.
    public let kind: MobileRemoteVaultRecordKind
    /// Encryption-key generation for this mutation.
    public let keyEpoch: Int64
    /// Monotonically increasing record revision.
    public let revision: Int64
    /// Authenticated deletion marker.
    public let deleted: Bool
    /// Device identity authorized by vault membership.
    public let writerDeviceID: UUID
    /// SHA-256 digest of the exact sealed record bytes.
    public let payloadDigest: Data
    /// Ed25519 signature over all fields except this signature.
    public private(set) var signature: Data?

    /// Creates bounded metadata, unsigned unless a received signature is supplied.
    /// - Parameters:
    ///   - accountID: Stable owner identity; not the current viewing member.
    ///   - vaultID: Vault whose authenticated membership governs this record.
    ///   - recordID: Opaque record identifier.
    ///   - kind: Authenticated record domain.
    ///   - keyEpoch: Positive encryption-key generation.
    ///   - revision: Positive record version; this type does not prove freshness.
    ///   - deleted: Whether this mutation deletes the record.
    ///   - writerDeviceID: Claimed writer; verify through trusted membership.
    ///   - payloadDigest: SHA-256 of the exact sealed record bytes.
    ///   - signature: Optional received 64-byte Ed25519 signature.
    /// - Throws: An error for malformed metadata before signing or verification.
    public init(
        accountID: String,
        vaultID: UUID,
        recordID: UUID,
        kind: MobileRemoteVaultRecordKind,
        keyEpoch: Int64,
        revision: Int64,
        deleted: Bool,
        writerDeviceID: UUID,
        payloadDigest: Data,
        signature: Data? = nil
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              keyEpoch > 0, revision > 0,
              payloadDigest.count == Self.digestLength,
              signature == nil || signature?.count == 64 else {
            throw MobileRemoteVaultError.invalidRevision
        }
        self.version = Self.currentVersion
        self.accountID = accountID
        self.vaultID = vaultID
        self.recordID = recordID
        self.kind = kind
        self.keyEpoch = keyEpoch
        self.revision = revision
        self.deleted = deleted
        self.writerDeviceID = writerDeviceID
        self.payloadDigest = payloadDigest
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case version, accountID, vaultID, recordID, kind, keyEpoch
        case revision, deleted, writerDeviceID, payloadDigest, signature
    }

    /// Decodes with the same bounds as explicit construction.
    /// - Parameter decoder: Decoder of a transport-bounded metadata record.
    /// - Throws: Unsupported-version, decoding, or malformed-metadata errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw MobileRemoteVaultError.unsupportedVersion(version)
        }
        try self.init(
            accountID: values.decode(String.self, forKey: .accountID),
            vaultID: values.decode(UUID.self, forKey: .vaultID),
            recordID: values.decode(UUID.self, forKey: .recordID),
            kind: values.decode(MobileRemoteVaultRecordKind.self, forKey: .kind),
            keyEpoch: values.decode(Int64.self, forKey: .keyEpoch),
            revision: values.decode(Int64.self, forKey: .revision),
            deleted: values.decode(Bool.self, forKey: .deleted),
            writerDeviceID: values.decode(UUID.self, forKey: .writerDeviceID),
            payloadDigest: values.decode(Data.self, forKey: .payloadDigest),
            signature: values.decodeIfPresent(Data.self, forKey: .signature)
        )
    }

    /// Returns a copy signed by a device private key.
    /// - Parameter key: Locally unlocked Ed25519 signing key.
    /// - Returns: Metadata with a signature binding all its fields.
    /// - Throws: CryptoKit signing errors.
    public func signed(by key: Curve25519.Signing.PrivateKey) throws -> Self {
        var copy = self
        copy.signature = try key.signature(for: signingData())
        return copy
    }

    /// Checks the writer signature, expected context, and exact payload together.
    ///
    /// The caller must resolve the expected writer and key from authenticated
    /// membership with write permission for this epoch. Never trust a public key
    /// supplied alongside a received revision.
    /// - Parameters:
    ///   - envelope: Encrypted record being accepted.
    ///   - context: Independently expected owner, record, epoch, and revision.
    ///   - writerDeviceID: Device selected from trusted membership.
    ///   - key: That device's trusted signing public key.
    /// - Throws: Authentication failure for any substitution or invalid signature.
    public func verify(
        envelope: MobileRemoteVaultEnvelope,
        context: MobileRemoteVaultContext,
        writerDeviceID: UUID,
        using key: Curve25519.Signing.PublicKey
    ) throws {
        guard accountID == context.accountID, vaultID == context.vaultID,
              recordID == context.recordID, kind == context.kind,
              keyEpoch == context.keyEpoch, revision == context.revision,
              deleted == context.deleted, self.writerDeviceID == writerDeviceID,
              payloadDigest == Self.digest(of: envelope),
              let signature,
              key.isValidSignature(signature, for: signingData()) else {
            throw MobileRemoteVaultError.invalidSignature
        }
    }

    /// Computes the digest of the sealed bytes bound by a revision.
    /// - Parameter envelope: Validated record envelope.
    /// - Returns: The 32-byte SHA-256 digest of nonce, ciphertext, and tag.
    public static func digest(of envelope: MobileRemoteVaultEnvelope) -> Data {
        Data(SHA256.hash(data: envelope.sealedBox))
    }

    private func signingData() -> Data {
        var data = Data("cmux.remote-vault.revision.v1".utf8)
        append(String(version), to: &data)
        append(accountID, to: &data)
        append(vaultID.uuidString.lowercased(), to: &data)
        append(recordID.uuidString.lowercased(), to: &data)
        append(kind.rawValue, to: &data)
        append(String(keyEpoch), to: &data)
        append(String(revision), to: &data)
        append(deleted ? "1" : "0", to: &data)
        append(writerDeviceID.uuidString.lowercased(), to: &data)
        append(payloadDigest, to: &data)
        return data
    }

    private func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private func append(_ value: Data, to data: inout Data) {
        var count = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(value)
    }
}
