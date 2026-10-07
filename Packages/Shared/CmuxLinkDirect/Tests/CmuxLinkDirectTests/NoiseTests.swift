@testable import CmuxLinkDirect
import CryptoKit
import Foundation
import Testing

/// `Noise_IK_25519_ChaChaPoly_SHA256` against the published cacophony test
/// vector (haskell-cryptography/cacophony, vectors/cacophony.txt).
@Suite("Noise IK")
struct NoiseTests {
    let prologue = Data(hex: "4a6f686e2047616c74")
    let initStatic = Data(hex: "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")
    let initEphemeral = Data(hex: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
    let respStatic = Data(hex: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")
    let respEphemeral = Data(hex: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")
    let remoteStatic = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62"
    let handshakeHash = "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7"
    let messages: [(payload: String, ciphertext: String)] = [
        ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"),
        ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"),
        ("462e20412e20486179656b", "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"),
        ("4361726c204d656e676572", "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"),
        ("4a65616e2d426170746973746520536179", "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"),
        ("457567656e2042f6686d20766f6e2042617765726b", "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024"),
    ]

    func key(_ data: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    @Test("matches the cacophony vector byte for byte")
    func cacophonyVector() throws {
        let responderKey = try key(respStatic)
        #expect(responderKey.publicKey.rawRepresentation.hex == remoteStatic)
        let pinned = try #require(DirectPublicKey(rawRepresentation: responderKey.publicKey.rawRepresentation))
        var initiator = NoiseInitiator(
            staticKey: try key(initStatic), remoteStatic: pinned, prologue: prologue, ephemeralKey: try key(initEphemeral)
        )
        var responder = NoiseResponder(staticKey: responderKey, prologue: prologue, ephemeralKey: try key(respEphemeral))

        let message1 = try initiator.writeMessage1(payload: Data(hex: messages[0].payload))
        #expect(message1.hex == messages[0].ciphertext)
        let (initiatorKey, payload1) = try responder.readMessage1(message1)
        #expect(payload1.hex == messages[0].payload)
        #expect(initiatorKey.rawRepresentation == (try key(initStatic)).publicKey.rawRepresentation)

        let (message2, responderCiphers) = try responder.writeMessage2(payload: Data(hex: messages[1].payload))
        #expect(message2.hex == messages[1].ciphertext)
        let (payload2, initiatorCiphers) = try initiator.readMessage2(message2)
        #expect(payload2.hex == messages[1].payload)
        #expect(initiatorCiphers.handshakeHash.hex == handshakeHash)
        #expect(responderCiphers.handshakeHash.hex == handshakeHash)

        var initiatorSide = initiatorCiphers
        var responderSide = responderCiphers
        for (index, message) in messages.enumerated().dropFirst(2) {
            let payload = Data(hex: message.payload)
            if index.isMultiple(of: 2) {
                let sealed = try initiatorSide.send.encrypt(payload)
                #expect(sealed.hex == message.ciphertext)
                #expect(try responderSide.receive.decrypt(sealed) == payload)
            } else {
                let sealed = try responderSide.send.encrypt(payload)
                #expect(sealed.hex == message.ciphertext)
                #expect(try initiatorSide.receive.decrypt(sealed) == payload)
            }
        }
    }

    @Test("a dialer pinning the wrong host key cannot complete message 1")
    func wrongPinnedKey() throws {
        let host = DirectIdentity()
        var initiator = NoiseInitiator(staticKey: DirectIdentity().privateKey, remoteStatic: DirectIdentity().publicKey, prologue: prologue)
        var responder = NoiseResponder(staticKey: host.privateKey, prologue: prologue)
        let message = try initiator.writeMessage1(payload: Data("hi".utf8))
        #expect(throws: NoiseError.decryptionFailed) { try responder.readMessage1(message) }
    }

    @Test("a different prologue fails the handshake")
    func prologueMismatch() throws {
        let host = DirectIdentity()
        var initiator = NoiseInitiator(staticKey: DirectIdentity().privateKey, remoteStatic: host.publicKey, prologue: Data("a".utf8))
        var responder = NoiseResponder(staticKey: host.privateKey, prologue: Data("b".utf8))
        let message = try initiator.writeMessage1(payload: Data())
        #expect(throws: NoiseError.decryptionFailed) { try responder.readMessage1(message) }
    }

    @Test("tampered, replayed and reordered transport messages fail")
    func transportIntegrity() throws {
        var (dialer, host) = try handshake()
        let first = try dialer.send.encrypt(Data("one".utf8))
        let second = try dialer.send.encrypt(Data("two".utf8))
        var tampered = first
        tampered[tampered.startIndex] ^= 0x01
        var probe = host.receive
        #expect(throws: NoiseError.decryptionFailed) { try probe.decrypt(tampered) }
        probe = host.receive
        #expect(throws: NoiseError.decryptionFailed) { try probe.decrypt(second) }
        #expect(try host.receive.decrypt(first) == Data("one".utf8))
        #expect(throws: NoiseError.decryptionFailed) { try host.receive.decrypt(first) }
        #expect(try host.receive.decrypt(second) == Data("two".utf8))
    }

    @Test("messages above the Noise limit are refused")
    func messageLimit() throws {
        var (dialer, _) = try handshake()
        #expect(throws: NoiseError.messageTooLarge) {
            try dialer.send.encrypt(Data(count: NoiseCipherState.maxMessageLength))
        }
        _ = try dialer.send.encrypt(Data(count: DirectRecord.maxPlaintext))
    }

    private func handshake() throws -> (NoiseTransportCiphers, NoiseTransportCiphers) {
        let host = DirectIdentity()
        var initiator = NoiseInitiator(staticKey: DirectIdentity().privateKey, remoteStatic: host.publicKey, prologue: prologue)
        var responder = NoiseResponder(staticKey: host.privateKey, prologue: prologue)
        _ = try responder.readMessage1(try initiator.writeMessage1(payload: Data()))
        let (reply, hostCiphers) = try responder.writeMessage2(payload: Data())
        let (_, dialerCiphers) = try initiator.readMessage2(reply)
        return (dialerCiphers, hostCiphers)
    }
}
