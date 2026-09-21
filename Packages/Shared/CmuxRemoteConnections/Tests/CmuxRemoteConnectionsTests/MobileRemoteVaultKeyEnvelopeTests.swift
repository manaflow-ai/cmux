import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteVaultKeyEnvelopeTests {
    @Test func approvedDeviceCanTransferVaultKeyToExactRecipient() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try MobileRemoteVaultKeyEnvelope.seal(
            vaultKey: vaultKey, accountID: accountID, vaultID: vaultID, keyEpoch: 3,
            senderDeviceID: senderID, senderSigningKey: sender,
            recipientDeviceID: recipientID, recipientEncryptionKey: recipient.publicKey
        )
        let opened = try envelope.open(
            recipientDeviceID: recipientID,
            recipientEncryptionKey: recipient,
            trustedSenderSigningKey: sender.publicKey
        )
        #expect(opened == vaultKey)
    }

    @Test func substitutionAndTamperingFailClosed() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let wrongSender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let wrongRecipient = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try MobileRemoteVaultKeyEnvelope.seal(
            vaultKey: vaultKey, accountID: accountID, vaultID: vaultID, keyEpoch: 3,
            senderDeviceID: senderID, senderSigningKey: sender,
            recipientDeviceID: recipientID, recipientEncryptionKey: recipient.publicKey
        )
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.signatureInvalid) {
            try envelope.open(
                recipientDeviceID: recipientID,
                recipientEncryptionKey: recipient,
                trustedSenderSigningKey: wrongSender.publicKey
            )
        }
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.signatureInvalid) {
            try envelope.open(
                recipientDeviceID: UUID(),
                recipientEncryptionKey: recipient,
                trustedSenderSigningKey: sender.publicKey
            )
        }
        let wrongAccount = try MobileRemoteVaultKeyEnvelope(
            accountID: "another-account", vaultID: envelope.vaultID,
            keyEpoch: envelope.keyEpoch, senderDeviceID: envelope.senderDeviceID,
            recipientDeviceID: envelope.recipientDeviceID,
            ephemeralPublicKey: envelope.ephemeralPublicKey, nonce: envelope.nonce,
            ciphertext: envelope.ciphertext, signature: envelope.signature
        )
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.signatureInvalid) {
            try wrongAccount.open(
                recipientDeviceID: recipientID,
                recipientEncryptionKey: recipient,
                trustedSenderSigningKey: sender.publicKey
            )
        }
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.decryptionFailed) {
            try envelope.open(
                recipientDeviceID: recipientID,
                recipientEncryptionKey: wrongRecipient,
                trustedSenderSigningKey: sender.publicKey
            )
        }
        var tamperedCiphertext = envelope.ciphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 1
        let tampered = try MobileRemoteVaultKeyEnvelope(
            accountID: envelope.accountID, vaultID: envelope.vaultID,
            keyEpoch: envelope.keyEpoch, senderDeviceID: envelope.senderDeviceID,
            recipientDeviceID: envelope.recipientDeviceID,
            ephemeralPublicKey: envelope.ephemeralPublicKey, nonce: envelope.nonce,
            ciphertext: tamperedCiphertext, signature: envelope.signature
        )
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.signatureInvalid) {
            try tampered.open(
                recipientDeviceID: recipientID,
                recipientEncryptionKey: recipient,
                trustedSenderSigningKey: sender.publicKey
            )
        }
    }

    @Test func boundsAndVersionsAreValidatedBeforeKeyWork() throws {
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.invalidEnvelope) {
            try MobileRemoteVaultKeyEnvelope.seal(
                vaultKey: Data(repeating: 1, count: 31), accountID: accountID,
                vaultID: vaultID, keyEpoch: 1, senderDeviceID: senderID,
                senderSigningKey: Curve25519.Signing.PrivateKey(),
                recipientDeviceID: recipientID,
                recipientEncryptionKey: Curve25519.KeyAgreement.PrivateKey().publicKey
            )
        }
        let invalidJSON = Data(#"{"version":99}"#.utf8)
        #expect(throws: MobileRemoteVaultKeyEnvelopeError.unsupportedVersion(99)) {
            try JSONDecoder().decode(MobileRemoteVaultKeyEnvelope.self, from: invalidJSON)
        }
    }

    private let vaultKey = Data((0..<32).map(UInt8.init))
    private let accountID = "account-1"
    private let vaultID = UUID(uuidString: "1B6B8B07-591F-4395-BA46-FD0E7AD0D302")!
    private let senderID = UUID(uuidString: "BA1B66B4-D0B8-49D9-9427-0D58EAE7BF10")!
    private let recipientID = UUID(uuidString: "DDC36C41-83C3-4F0B-8E34-A2A8B737C3D2")!
}
