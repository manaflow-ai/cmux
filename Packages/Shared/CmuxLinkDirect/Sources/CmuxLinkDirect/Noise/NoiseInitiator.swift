import CryptoKit
import Foundation

/// The IK initiator (the dialer): knows the responder's static key.
///
/// ```
/// <- s
/// ...
/// -> e, es, s, ss
/// <- e, ee, se
/// ```
struct NoiseInitiator: Sendable {
    private let noise = NoiseProtocol()
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Data
    private var state: NoiseSymmetricState

    init(
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: DirectPublicKey,
        prologue: Data,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) {
        self.staticKey = staticKey
        self.ephemeralKey = ephemeralKey
        self.remoteStatic = remoteStatic.rawRepresentation
        state = noise.initialState(prologue: prologue, responderStatic: remoteStatic.rawRepresentation)
    }

    mutating func writeMessage1(payload: Data) throws -> Data {
        let ephemeral = ephemeralKey.publicKey.rawRepresentation
        state.mixHash(ephemeral)
        state.mixKey(try noise.dh(ephemeralKey, remoteStatic))
        let encryptedStatic = try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
        state.mixKey(try noise.dh(staticKey, remoteStatic))
        let encryptedPayload = try state.encryptAndHash(payload)
        return ephemeral + encryptedStatic + encryptedPayload
    }

    mutating func readMessage2(_ message: Data) throws -> (payload: Data, ciphers: NoiseTransportCiphers) {
        let message = Data(message)
        guard message.count >= noise.keyLength + NoiseCipherState.tagLength else { throw NoiseError.malformedMessage }
        let remoteEphemeral = message.prefix(noise.keyLength)
        state.mixHash(remoteEphemeral)
        state.mixKey(try noise.dh(ephemeralKey, remoteEphemeral))
        state.mixKey(try noise.dh(staticKey, remoteEphemeral))
        let payload = try state.decryptAndHash(message.dropFirst(noise.keyLength))
        let (send, receive) = state.split()
        return (payload, NoiseTransportCiphers(send: send, receive: receive, handshakeHash: state.handshakeHash))
    }
}
