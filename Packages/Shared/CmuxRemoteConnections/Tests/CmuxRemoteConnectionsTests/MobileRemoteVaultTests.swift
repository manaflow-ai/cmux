import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteVaultTests {
    let cipher = MobileRemoteVaultCipher()

    @Test func opensIndependentPythonAESGCMVector() throws {
        // Generated with cryptography 50.0.1 AESGCM, bytes(0..<32) as the
        // public test key, bytes(0..<12) as the test nonce, and the v1
        // length-prefixed associated-data fields. Production uses random nonces.
        let combined = try #require(Data(base64Encoded:
            "AAECAwQFBgcICQoLJG+jY+iVt3nhKPSmxYwLGa6g4leEFC37Fbv4gBRuPXNdmISzY9St"
        ))
        let envelope = try MobileRemoteVaultEnvelope(sealedBox: combined)
        let opened = try cipher.decrypt(
            envelope, context: context(), key: SymmetricKey(data: Data(0..<32))
        )
        #expect(opened == Data("cmux-public-test-vector".utf8))
    }

    @Test func roundTripsAfterSerializationWithFreshNonces() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try context()
        let secret = Data("test-only-private-key-material".utf8)
        let first = try cipher.encrypt(secret, context: context, key: key)
        let second = try cipher.encrypt(secret, context: context, key: key)
        #expect(first.sealedBox != second.sealedBox)
        let encoded = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode(MobileRemoteVaultEnvelope.self, from: encoded)
        #expect(try cipher.decrypt(restored, context: context, key: key) == secret)
    }

    @Test func rejectsSubstitutionAcrossEveryOwnershipAndVersionField() throws {
        let key = SymmetricKey(size: .bits256)
        let original = try context()
        let sealed = try cipher.encrypt(Data("secret".utf8), context: original, key: key)
        let others = try [
            context(account: "another-account"),
            context(vault: UUID()),
            context(record: UUID()),
            context(kind: .profile),
            context(epoch: 2),
            context(revision: 2),
            context(deleted: true)
        ]
        for other in others {
            #expect(throws: MobileRemoteVaultError.authenticationFailed) {
                try cipher.decrypt(sealed, context: other, key: key)
            }
        }
    }

    @Test func rejectsWrongKeyAndMutatedNonceCiphertextOrTag() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try context()
        let sealed = try cipher.encrypt(Data("secret".utf8), context: context, key: key)
        #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try cipher.decrypt(sealed, context: context, key: SymmetricKey(size: .bits256))
        }
        for offset in [0, 12, sealed.sealedBox.count - 1] {
            var changed = sealed.sealedBox
            changed[offset] ^= 1
            let tampered = try MobileRemoteVaultEnvelope(sealedBox: changed)
            #expect(throws: MobileRemoteVaultError.authenticationFailed) {
                try cipher.decrypt(tampered, context: context, key: key)
            }
        }
    }

    @Test func authenticatesDeletionAndRejectsHiddenLiveData() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try context(deleted: true)
        let deleted = try cipher.encrypt(Data(), context: context, key: key)
        #expect(try cipher.decrypt(deleted, context: context, key: key).isEmpty)
        #expect(throws: MobileRemoteVaultError.invalidDeletionPayload) {
            try cipher.encrypt(Data([42]), context: context, key: key)
        }
    }

    @Test func rejectsShortKeysAndOversizedPayloads() throws {
        let context = try context()
        #expect(throws: MobileRemoteVaultError.invalidKeySize) {
            try cipher.encrypt(Data(), context: context, key: SymmetricKey(size: .bits128))
        }
        #expect(throws: MobileRemoteVaultError.payloadTooLarge) {
            try cipher.encrypt(
                Data(repeating: 1, count: MobileRemoteVaultEnvelope.maximumPayloadBytes + 1),
                context: context, key: SymmetricKey(size: .bits256)
            )
        }
    }

    @Test func decoderRejectsUnsupportedAndTruncatedEnvelopes() throws {
        for (data, error) in [
            (Data(#"{"version":2,"sealedBox":""}"#.utf8), MobileRemoteVaultError.unsupportedVersion(2)),
            (Data(#"{"version":1,"sealedBox":""}"#.utf8), MobileRemoteVaultError.malformedEnvelope)
        ] {
            #expect(throws: error) {
                try JSONDecoder().decode(MobileRemoteVaultEnvelope.self, from: data)
            }
        }
    }

    @Test func rejectsInvalidOwnerAndVersionContext() throws {
        #expect(throws: MobileRemoteVaultError.invalidContext) { try context(account: "") }
        #expect(throws: MobileRemoteVaultError.invalidContext) { try context(account: "a\0b") }
        #expect(throws: MobileRemoteVaultError.invalidContext) { try context(epoch: 0) }
        #expect(throws: MobileRemoteVaultError.invalidContext) { try context(revision: -1) }
    }

    private func context(
        account: String = "account-1",
        vault: UUID = UUID(uuidString: "1B6B8B07-591F-4395-BA46-FD0E7AD0D302")!,
        record: UUID = UUID(uuidString: "C2C4EC54-58B9-47C6-BB45-21774579B13B")!,
        kind: MobileRemoteVaultRecordKind = .credential,
        epoch: Int64 = 1,
        revision: Int64 = 1,
        deleted: Bool = false
    ) throws -> MobileRemoteVaultContext {
        try MobileRemoteVaultContext(
            accountID: account, vaultID: vault, recordID: record,
            kind: kind, keyEpoch: epoch, revision: revision, deleted: deleted
        )
    }
}
