import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteVaultSyncTests {
    @Test func signedRevisionVerifiesExactCiphertextAndWriter() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try MobileRemoteVaultContext(
            accountID: "account-1", vaultID: vaultID, recordID: recordID,
            kind: .profile, keyEpoch: 2, revision: 7
        )
        let envelope = try MobileRemoteVaultCipher().encrypt(
            Data("private-profile".utf8), context: context, key: key
        )
        let signingKey = Curve25519.Signing.PrivateKey()
        let unsigned = try MobileRemoteVaultRevision(
            accountID: context.accountID, vaultID: context.vaultID,
            recordID: context.recordID, kind: context.kind,
            keyEpoch: context.keyEpoch, revision: context.revision,
            deleted: context.deleted, writerDeviceID: deviceID,
            payloadDigest: MobileRemoteVaultRevision.digest(of: envelope)
        )
        let signed = try unsigned.signed(by: signingKey)
        try signed.verify(
            envelope: envelope, context: context,
            writerDeviceID: deviceID, using: signingKey.publicKey
        )
        #expect(signed.signature?.count == 64)
    }

    @Test func revisionRejectsUnsignedTamperedAndWrongWriterMetadata() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let context = try MobileRemoteVaultContext(
            accountID: "account-1", vaultID: vaultID, recordID: recordID,
            kind: .credential, keyEpoch: 1, revision: 1
        )
        let key = SymmetricKey(size: .bits256)
        let envelope = try MobileRemoteVaultCipher().encrypt(
            Data("credential".utf8), context: context, key: key
        )
        let unsignedWithDigest = try MobileRemoteVaultRevision(
            accountID: context.accountID, vaultID: context.vaultID,
            recordID: context.recordID, kind: context.kind,
            keyEpoch: context.keyEpoch, revision: context.revision,
            deleted: context.deleted, writerDeviceID: deviceID,
            payloadDigest: MobileRemoteVaultRevision.digest(of: envelope)
        )
        #expect(throws: MobileRemoteVaultError.invalidSignature) {
            try unsignedWithDigest.verify(
                envelope: envelope, context: context,
                writerDeviceID: deviceID, using: signingKey.publicKey
            )
        }
        let signed = try unsignedWithDigest.signed(by: signingKey)
        try signed.verify(
            envelope: envelope, context: context,
            writerDeviceID: deviceID, using: signingKey.publicKey
        )
        let tampered = try MobileRemoteVaultRevision(
            accountID: signed.accountID, vaultID: signed.vaultID, recordID: signed.recordID,
            kind: signed.kind, keyEpoch: signed.keyEpoch, revision: signed.revision + 1,
            deleted: signed.deleted, writerDeviceID: signed.writerDeviceID,
            payloadDigest: signed.payloadDigest, signature: signed.signature
        )
        #expect(throws: MobileRemoteVaultError.invalidSignature) {
            try tampered.verify(
                envelope: envelope, context: context,
                writerDeviceID: deviceID, using: signingKey.publicKey
            )
        }
        #expect(throws: MobileRemoteVaultError.invalidSignature) {
            try signed.verify(
                envelope: envelope, context: context,
                writerDeviceID: deviceID,
                using: Curve25519.Signing.PrivateKey().publicKey
            )
        }
    }

    @Test func revisionBoundsDigestAndSignatureWithoutLeakingPayload() throws {
        #expect(throws: MobileRemoteVaultError.invalidRevision) {
            try MobileRemoteVaultRevision(
                accountID: "account-1", vaultID: vaultID, recordID: recordID,
                kind: .credential, keyEpoch: 1, revision: 1, deleted: false,
                writerDeviceID: deviceID, payloadDigest: Data(repeating: 1, count: 31)
            )
        }
        #expect(throws: MobileRemoteVaultError.invalidRevision) {
            try MobileRemoteVaultRevision(
                accountID: "account-1", vaultID: vaultID, recordID: recordID,
                kind: .credential, keyEpoch: 1, revision: 1, deleted: false,
                writerDeviceID: deviceID, payloadDigest: Data(repeating: 1, count: 32),
                signature: Data(repeating: 1, count: 63)
            )
        }
        let policy = try MobileRemoteVaultRecoveryPolicy(
            scope: .team(organizationID: "org-1"), organizationRecoveryKeyID: UUID()
        )
        #expect(policy.organizationRecoveryKeyID != nil)
    }

    @Test func recoveryPolicySeparatesPersonalAndOrganizationAuthority() throws {
        #expect(try MobileRemoteVaultRecoveryPolicy(scope: .personal).organizationRecoveryKeyID == nil)
        #expect(try MobileRemoteVaultRecoveryPolicy(scope: .team(organizationID: "org-1"), organizationRecoveryKeyID: nil).organizationRecoveryKeyID == nil)
        #expect(throws: MobileRemoteVaultRecoveryError.organizationRecoveryRequiresTeam) {
            try MobileRemoteVaultRecoveryPolicy(
                scope: .personal, organizationRecoveryKeyID: UUID()
            )
        }
        #expect(throws: MobileRemoteVaultRecoveryError.invalidOrganization) {
            try MobileRemoteVaultRecoveryPolicy(
                scope: .team(organizationID: "\0"), organizationRecoveryKeyID: UUID()
            )
        }
    }

    private let vaultID = UUID(uuidString: "1B6B8B07-591F-4395-BA46-FD0E7AD0D302")!
    private let recordID = UUID(uuidString: "C2C4EC54-58B9-47C6-BB45-21774579B13B")!
    private let deviceID = UUID(uuidString: "BA1B66B4-D0B8-49D9-9427-0D58EAE7BF10")!
}
