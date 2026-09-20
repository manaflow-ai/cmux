public import CryptoKit
public import Foundation

/// Signed, account-bound membership and recovery policy for one vault generation.
///
/// Decoding checks shape only. Use ``MobileRemoteVaultManifestVerifier`` before
/// trusting participants, distributing keys, or authorizing record writes.
public struct MobileRemoteVaultManifest: Codable, Equatable, Sendable {
    /// Current signed membership wire format.
    public static let currentVersion = 1
    /// Maximum number of retained device entries, including revoked devices.
    public static let maximumParticipants = 256
    /// Signed format version.
    public let version: Int
    /// Stable namespace account, independent of the current viewer or team member.
    public let accountID: String
    /// Stable vault identifier.
    public let vaultID: UUID
    /// Monotonic membership revision, starting at one.
    public let revision: Int64
    /// Encryption-key generation shared by active participants.
    public let keyEpoch: Int64
    /// Digest of the previous manifest's canonical body, absent only at revision one.
    public let previousDigest: Data?
    /// Device that signs this change using authority from the previous membership.
    public let signerDeviceID: UUID
    /// Device membership in canonical device-identifier order.
    public let participants: [MobileRemoteVaultParticipant]
    /// Explicit personal/team scope and organization recovery choice.
    public let recoveryPolicy: MobileRemoteVaultRecoveryPolicy
    /// X25519 key for the policy's organization recovery identity, if enabled.
    public let organizationRecoveryPublicKey: Data?
    /// Ed25519 signature over all preceding fields, absent on an unsigned proposal.
    public private(set) var signature: Data?

    /// Creates a bounded policy proposal or received signed manifest.
    /// - Parameters:
    ///   - accountID: Stable vault namespace established at creation.
    ///   - vaultID: Independently selected vault identity.
    ///   - revision: Positive membership revision.
    ///   - keyEpoch: Positive encryption-key generation.
    ///   - previousDigest: Previous canonical body digest, or nil for genesis.
    ///   - signerDeviceID: Device authorized to administer the previous membership.
    ///   - participants: Unique account-bound devices, with at least one active owner.
    ///   - recoveryPolicy: Explicit vault scope and recovery recipient identity.
    ///   - organizationRecoveryPublicKey: Required exactly when organization recovery is enabled.
    ///   - signature: Optional 64-byte received signature; nil creates an unsigned proposal.
    /// - Throws: Shape, scope, duplicate identity, or recovery-policy errors.
    public init(
        accountID: String,
        vaultID: UUID,
        revision: Int64,
        keyEpoch: Int64,
        previousDigest: Data?,
        signerDeviceID: UUID,
        participants: [MobileRemoteVaultParticipant],
        recoveryPolicy: MobileRemoteVaultRecoveryPolicy,
        organizationRecoveryPublicKey: Data? = nil,
        signature: Data? = nil
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              revision > 0, keyEpoch > 0,
              (revision == 1 ? previousDigest == nil : previousDigest?.count == 32),
              (1...Self.maximumParticipants).contains(participants.count),
              signature == nil || signature?.count == 64 else {
            throw MobileRemoteVaultManifestError.invalidManifest
        }
        try recoveryPolicy.scope.validate()
        if case .personal = recoveryPolicy.scope {
            guard participants.allSatisfy({ $0.accountID == accountID }) else {
                throw MobileRemoteVaultManifestError.contextMismatch
            }
        }
        guard participants.allSatisfy({
            $0.member.revoked ? $0.member.keyEpoch <= keyEpoch : $0.member.keyEpoch == keyEpoch
        }) else { throw MobileRemoteVaultManifestError.invalidParticipant }
        guard Set(participants.map { $0.member.deviceID }).count == participants.count,
              Set(participants.map { $0.member.signingPublicKey }).count == participants.count,
              Set(participants.map(\.encryptionPublicKey)).count == participants.count else {
            throw MobileRemoteVaultManifestError.duplicateParticipant
        }
        guard participants.contains(where: { !$0.member.revoked && $0.member.role == .owner }) else {
            throw MobileRemoteVaultManifestError.missingOwner
        }
        if let recoveryID = recoveryPolicy.organizationRecoveryKeyID {
            guard case .team = recoveryPolicy.scope,
                  let key = organizationRecoveryPublicKey, key.count == 32,
                  (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil,
                  !participants.contains(where: {
                      $0.member.deviceID == recoveryID || $0.encryptionPublicKey == key
                  }) else { throw MobileRemoteVaultManifestError.invalidRecoveryRecipient }
        } else if organizationRecoveryPublicKey != nil {
            throw MobileRemoteVaultManifestError.invalidRecoveryRecipient
        }
        self.version = Self.currentVersion
        self.accountID = accountID
        self.vaultID = vaultID
        self.revision = revision
        self.keyEpoch = keyEpoch
        self.previousDigest = previousDigest
        self.signerDeviceID = signerDeviceID
        self.participants = participants.sorted { $0.member.deviceID.uuidString < $1.member.deviceID.uuidString }
        self.recoveryPolicy = recoveryPolicy
        self.organizationRecoveryPublicKey = organizationRecoveryPublicKey
        self.signature = signature
    }

    /// SHA-256 of the canonical body, used for approval and predecessor binding.
    ///
    /// Excludes the signature so re-signing identical content cannot create a
    /// different chain identity. This digest alone does not establish trust.
    public var digest: Data { Data(SHA256.hash(data: signingData())) }

    /// Signs a proposal without granting the signer's claimed authority.
    /// - Parameter key: Unlocked local Ed25519 signing key.
    /// - Returns: A signed copy, still requiring membership verification.
    /// - Throws: CryptoKit signing failures.
    public func signed(by key: Curve25519.Signing.PrivateKey) throws -> Self {
        var result = self
        result.signature = try key.signature(for: signingData())
        return result
    }

    func verifySignature(using key: Curve25519.Signing.PublicKey) throws {
        guard let signature, key.isValidSignature(signature, for: signingData()) else {
            throw MobileRemoteVaultManifestError.invalidSignature
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, accountID, vaultID, revision, keyEpoch, previousDigest
        case signerDeviceID, participants, recoveryPolicy, organizationRecoveryPublicKey, signature
    }

    /// Decodes a manifest without trusting its membership or signature.
    /// - Parameter decoder: Decoder for a size-bounded transport message.
    /// - Throws: Decoding or the same validation errors as explicit construction.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw MobileRemoteVaultManifestError.invalidManifest
        }
        var entries = try values.nestedUnkeyedContainer(forKey: .participants)
        var participants: [MobileRemoteVaultParticipant] = []
        while !entries.isAtEnd {
            guard participants.count < Self.maximumParticipants else {
                throw MobileRemoteVaultManifestError.invalidManifest
            }
            participants.append(try entries.decode(MobileRemoteVaultParticipant.self))
        }
        try self.init(
            accountID: values.decode(String.self, forKey: .accountID),
            vaultID: values.decode(UUID.self, forKey: .vaultID),
            revision: values.decode(Int64.self, forKey: .revision),
            keyEpoch: values.decode(Int64.self, forKey: .keyEpoch),
            previousDigest: values.decodeIfPresent(Data.self, forKey: .previousDigest),
            signerDeviceID: values.decode(UUID.self, forKey: .signerDeviceID),
            participants: participants,
            recoveryPolicy: values.decode(MobileRemoteVaultRecoveryPolicy.self, forKey: .recoveryPolicy),
            organizationRecoveryPublicKey: values.decodeIfPresent(Data.self, forKey: .organizationRecoveryPublicKey),
            signature: values.decodeIfPresent(Data.self, forKey: .signature)
        )
    }

    /// Length prefixes and an explicit domain make the signed bytes unambiguous.
    private func signingData() -> Data {
        var body = SigningBody()
        body.append(String(version))
        body.append(accountID)
        body.append(vaultID.uuidString.lowercased())
        body.append(String(revision))
        body.append(String(keyEpoch))
        body.append(previousDigest ?? Data())
        body.append(signerDeviceID.uuidString.lowercased())
        switch recoveryPolicy.scope {
        case .personal: body.append("personal"); body.append("")
        case let .team(organizationID): body.append("team"); body.append(organizationID)
        }
        body.append(recoveryPolicy.organizationRecoveryKeyID?.uuidString.lowercased() ?? "")
        body.append(organizationRecoveryPublicKey ?? Data())
        body.append(String(participants.count))
        for participant in participants {
            body.append(participant.accountID)
            body.append(participant.member.deviceID.uuidString.lowercased())
            body.append(participant.member.role.rawValue)
            body.append(participant.member.signingPublicKey)
            body.append(String(participant.member.keyEpoch))
            body.append(participant.member.revoked ? "1" : "0")
            body.append(participant.encryptionPublicKey)
        }
        return body.data
    }

    private struct SigningBody {
        var data = Data("cmux.remote-vault.manifest.v1".utf8)
        mutating func append(_ value: String) { append(Data(value.utf8)) }
        mutating func append(_ value: Data) {
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(value)
        }
    }
}
