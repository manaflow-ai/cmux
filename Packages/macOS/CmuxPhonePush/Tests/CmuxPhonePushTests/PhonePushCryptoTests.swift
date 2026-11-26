import CryptoKit
import Foundation
import Testing
@testable import CmuxPhonePush

@Suite("Phone push HPKE")
struct PhonePushCryptoTests {
    private let tuple = PhonePushDeviceTuple(
        accountID: "account-1",
        teamID: "team-1",
        iosBuildID: "dev.cmux.ios",
        iosInstallationID: "ios-install-1",
        macDeviceID: "mac-1",
        macInstanceTag: "agent",
        macBuildID: "dev.cmux.app"
    )

    @Test("round trips through the production v2 serializer")
    func roundTrip() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try PhonePushCrypto().encrypt(
            plaintext: Data(#"{"replyId":"reply-1","text":"hello"}"#.utf8),
            tuple: tuple,
            recipientPublicKey: recipient.publicKey.rawRepresentation,
            keyID: "ios-key-1",
            senderKeyID: "mac-key-1",
            senderPrivateKey: sender,
            installationID: tuple.iosInstallationID
        )
        let wire = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(PhonePushEncryptedPayload.self, from: wire)
        let plaintext = try PhonePushCrypto().decrypt(
            envelope: decoded,
            tuple: tuple,
            recipientInstallationID: tuple.iosInstallationID,
            recipientKeyID: "ios-key-1",
            trustedSenderKeyID: "mac-key-1",
            senderPublicKey: sender.publicKey.rawRepresentation,
            privateKey: recipient
        )
        #expect(plaintext == Data(#"{"replyId":"reply-1","text":"hello"}"#.utf8))
    }

    @Test("rejects tuple, recipient key, and sender key mismatches")
    func rejectsBindingMismatches() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try PhonePushCrypto().encrypt(
            plaintext: Data("secret".utf8),
            tuple: tuple,
            recipientPublicKey: recipient.publicKey.rawRepresentation,
            keyID: "ios-key-1",
            senderKeyID: "mac-key-1",
            senderPrivateKey: sender,
            installationID: tuple.iosInstallationID
        )
        #expect(throws: PhonePushCryptoError.self) {
            try PhonePushCrypto().decrypt(
                envelope: envelope,
                tuple: PhonePushDeviceTuple(
                    accountID: "other-account",
                    teamID: tuple.teamID,
                    iosBuildID: tuple.iosBuildID,
                    iosInstallationID: tuple.iosInstallationID,
                    macDeviceID: tuple.macDeviceID,
                    macInstanceTag: tuple.macInstanceTag,
                    macBuildID: tuple.macBuildID
                ),
                recipientInstallationID: tuple.iosInstallationID,
                recipientKeyID: "ios-key-1",
                trustedSenderKeyID: "mac-key-1",
                senderPublicKey: sender.publicKey.rawRepresentation,
                privateKey: recipient
            )
        }
        #expect(throws: PhonePushCryptoError.self) {
            try PhonePushCrypto().decrypt(
                envelope: envelope,
                tuple: tuple,
                recipientInstallationID: tuple.iosInstallationID,
                recipientKeyID: "wrong-key",
                trustedSenderKeyID: "mac-key-1",
                senderPublicKey: sender.publicKey.rawRepresentation,
                privateKey: recipient
            )
        }
        #expect(throws: PhonePushCryptoError.self) {
            try PhonePushCrypto().decrypt(
                envelope: envelope,
                tuple: tuple,
                recipientInstallationID: tuple.iosInstallationID,
                recipientKeyID: "ios-key-1",
                trustedSenderKeyID: "wrong-sender",
                senderPublicKey: sender.publicKey.rawRepresentation,
                privateKey: recipient
            )
        }
    }

    @Test("rejects replayed, future, and overlong authenticated timestamps")
    func replyFreshness() {
        #expect(PhonePushReplyFreshness().accepts(issuedAt: 1_000, expiresAt: 1_900, now: 1_100))
        #expect(!PhonePushReplyFreshness().accepts(issuedAt: 1_000, expiresAt: 1_900, now: 2_000))
        #expect(!PhonePushReplyFreshness().accepts(issuedAt: 2_000, expiresAt: 2_900, now: 1_000))
        #expect(!PhonePushReplyFreshness().accepts(issuedAt: 1_000, expiresAt: 16_001, now: 1_100))
    }
}
