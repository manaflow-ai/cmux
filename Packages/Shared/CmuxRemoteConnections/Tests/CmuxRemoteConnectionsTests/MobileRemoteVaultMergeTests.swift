import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteVaultMergeTests {
    @Test func acceptsEditorAndMakesExactReplayIdempotent() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let policy = try makePolicy(key: signingKey, role: .editor)
        let (envelope, revision) = try makeRecord(key: signingKey, revision: 4)
        #expect(try await policy.apply(envelope: envelope, revision: revision) == .applied)
        #expect(try await policy.apply(envelope: envelope, revision: revision) == .duplicate)
        #expect(await policy.revision(for: recordID) == 4)
    }

    @Test func rejectsViewerRecoveryRevokedWrongKeyAndWrongScopeWriters() async throws {
        let viewerKey = Curve25519.Signing.PrivateKey()
        let viewerPolicy = try makePolicy(key: viewerKey, role: .viewer)
        let (viewerEnvelope, viewerRevision) = try makeRecord(key: viewerKey, revision: 1)
        await #expect(throws: MobileRemoteVaultMergeError.writerNotAuthorized) {
            try await viewerPolicy.apply(envelope: viewerEnvelope, revision: viewerRevision)
        }

        let revokedKey = Curve25519.Signing.PrivateKey()
        let revokedPolicy = try makePolicy(key: revokedKey, role: .editor, revoked: true)
        let (revokedEnvelope, revokedRevision) = try makeRecord(key: revokedKey, revision: 1)
        await #expect(throws: MobileRemoteVaultMergeError.writerNotAuthorized) {
            try await revokedPolicy.apply(envelope: revokedEnvelope, revision: revokedRevision)
        }

        let writer = Curve25519.Signing.PrivateKey()
        let policy = try makePolicy(key: writer, role: .editor)
        let (envelope, revision) = try makeRecord(key: writer, revision: 1)
        let wrongKey = Curve25519.Signing.PrivateKey()
        let wrongSigned = try makeRevision(
            key: wrongKey, writerID: deviceID, revision: 2, envelope: envelope
        )
        await #expect(throws: MobileRemoteVaultMergeError.invalidSignature) {
            try await policy.apply(envelope: envelope, revision: wrongSigned)
        }
        let wrongAccount = try MobileRemoteVaultRevision(
            accountID: "another-account", vaultID: vaultID, recordID: recordID,
            kind: revision.kind, keyEpoch: 1, revision: 2, deleted: false,
            writerDeviceID: deviceID, payloadDigest: revision.payloadDigest
        ).signed(by: writer)
        await #expect(throws: MobileRemoteVaultMergeError.contextMismatch) {
            try await policy.apply(envelope: envelope, revision: wrongAccount)
        }
    }

    @Test func rejectsRollbackAndSameRevisionConflictsAndKeepsTombstone() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let secondKey = Curve25519.Signing.PrivateKey()
        let policy = try MobileRemoteVaultMergePolicy(
            accountID: accountID,
            vaultID: vaultID,
            keyEpoch: 1,
            members: [
                try member(key: signingKey, deviceID: deviceID, role: .owner),
                try member(key: secondKey, deviceID: secondDeviceID, role: .editor),
            ]
        )
        let (firstEnvelope, first) = try makeRecord(key: signingKey, revision: 5)
        #expect(try await policy.apply(envelope: firstEnvelope, revision: first) == .applied)

        let sameRevisionOtherWriter = try makeRevision(
            key: secondKey,
            writerID: secondDeviceID,
            revision: 5,
            envelope: firstEnvelope
        )
        await #expect(throws: MobileRemoteVaultMergeError.conflictingRevision) {
            try await policy.apply(envelope: firstEnvelope, revision: sameRevisionOtherWriter)
        }

        let (staleEnvelope, stale) = try makeRecord(key: signingKey, revision: 4)
        await #expect(throws: MobileRemoteVaultMergeError.staleRevision) {
            try await policy.apply(envelope: staleEnvelope, revision: stale)
        }

        let deleteContext = try MobileRemoteVaultContext(
            accountID: accountID, vaultID: vaultID, recordID: recordID,
            kind: .profile, keyEpoch: 1, revision: 6, deleted: true
        )
        let deleteEnvelope = try MobileRemoteVaultCipher().encrypt(
            Data(), context: deleteContext, key: SymmetricKey(size: .bits256)
        )
        let deleteRevision = try makeRevision(
            key: signingKey, writerID: deviceID, revision: 6,
            envelope: deleteEnvelope, deleted: true
        )
        #expect(try await policy.apply(envelope: deleteEnvelope, revision: deleteRevision) == .applied)
        #expect(await policy.isDeleted(recordID: recordID))

        var conflictBytes = deleteEnvelope.sealedBox
        conflictBytes[conflictBytes.startIndex] ^= 1
        let conflictingEnvelope = try MobileRemoteVaultEnvelope(sealedBox: conflictBytes)
        let conflictingRevision = try makeRevision(
            key: signingKey, writerID: deviceID, revision: 6,
            envelope: conflictingEnvelope, deleted: true
        )
        await #expect(throws: MobileRemoteVaultMergeError.conflictingRevision) {
            try await policy.apply(envelope: conflictingEnvelope, revision: conflictingRevision)
        }
    }

    private func makePolicy(
        key: Curve25519.Signing.PrivateKey,
        role: MobileRemoteVaultMemberRole,
        revoked: Bool = false
    ) throws -> MobileRemoteVaultMergePolicy {
        let member = try member(key: key, deviceID: deviceID, role: role, revoked: revoked)
        return try MobileRemoteVaultMergePolicy(
            accountID: accountID, vaultID: vaultID, keyEpoch: 1, members: [member]
        )
    }

    private func member(
        key: Curve25519.Signing.PrivateKey,
        deviceID: UUID,
        role: MobileRemoteVaultMemberRole,
        revoked: Bool = false
    ) throws -> MobileRemoteVaultMember {
        try MobileRemoteVaultMember(
            deviceID: deviceID, role: role,
            signingPublicKey: key.publicKey.rawRepresentation,
            keyEpoch: 1, revoked: revoked
        )
    }

    private func makeRecord(
        key: Curve25519.Signing.PrivateKey,
        revision: Int64
    ) throws -> (MobileRemoteVaultEnvelope, MobileRemoteVaultRevision) {
        let context = try MobileRemoteVaultContext(
            accountID: accountID, vaultID: vaultID, recordID: recordID,
            kind: .profile, keyEpoch: 1, revision: revision
        )
        let envelope = try MobileRemoteVaultCipher().encrypt(
            Data("encrypted-profile".utf8), context: context,
            key: SymmetricKey(size: .bits256)
        )
        return (envelope, try makeRevision(
            key: key, writerID: deviceID, revision: revision, envelope: envelope
        ))
    }

    private func makeRevision(
        key: Curve25519.Signing.PrivateKey,
        writerID: UUID,
        revision: Int64,
        envelope: MobileRemoteVaultEnvelope,
        deleted: Bool = false
    ) throws -> MobileRemoteVaultRevision {
        try MobileRemoteVaultRevision(
            accountID: accountID, vaultID: vaultID, recordID: recordID,
            kind: .profile, keyEpoch: 1, revision: revision, deleted: deleted,
            writerDeviceID: writerID,
            payloadDigest: MobileRemoteVaultRevision.digest(of: envelope)
        ).signed(by: key)
    }

    private let accountID = "account-1"
    private let vaultID = UUID(uuidString: "1B6B8B07-591F-4395-BA46-FD0E7AD0D302")!
    private let recordID = UUID(uuidString: "C2C4EC54-58B9-47C6-BB45-21774579B13B")!
    private let deviceID = UUID(uuidString: "BA1B66B4-D0B8-49D9-9427-0D58EAE7BF10")!
    private let secondDeviceID = UUID(uuidString: "DDC36C41-83C3-4F0B-8E34-A2A8B737C3D2")!
}
