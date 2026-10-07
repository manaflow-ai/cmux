import CryptoKit
import Foundation

/// The IK responder (the host): learns the initiator's static key from
/// message 1 and decides whether to answer.
struct NoiseResponder: Sendable {
    private let noise = NoiseProtocol()
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private var state: NoiseSymmetricState
    private var remoteEphemeral = Data()
    private var remoteStatic = Data()

    init(
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        prologue: Data,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) {
        self.staticKey = staticKey
        self.ephemeralKey = ephemeralKey
        state = noise.initialState(prologue: prologue, responderStatic: staticKey.publicKey.rawRepresentation)
    }

    mutating func readMessage1(_ message: Data) throws -> (remoteStatic: DirectPublicKey, payload: Data) {
        let message = Data(message)
        let staticLength = noise.keyLength + NoiseCipherState.tagLength
        guard message.count >= noise.keyLength + staticLength + NoiseCipherState.tagLength else {
            throw NoiseError.malformedMessage
        }
        remoteEphemeral = Data(message.prefix(noise.keyLength))
        state.mixHash(remoteEphemeral)
        state.mixKey(try noise.dh(staticKey, remoteEphemeral))
        let staticStart = message.startIndex + noise.keyLength
        remoteStatic = try state.decryptAndHash(message[staticStart..<(staticStart + staticLength)])
        state.mixKey(try noise.dh(staticKey, remoteStatic))
        let payload = try state.decryptAndHash(message[(staticStart + staticLength)...])
        guard let key = DirectPublicKey(rawRepresentation: remoteStatic) else { throw NoiseError.malformedMessage }
        return (key, payload)
    }

    mutating func writeMessage2(payload: Data) throws -> (message: Data, ciphers: NoiseTransportCiphers) {
        let ephemeral = ephemeralKey.publicKey.rawRepresentation
        state.mixHash(ephemeral)
        state.mixKey(try noise.dh(ephemeralKey, remoteEphemeral))
        state.mixKey(try noise.dh(ephemeralKey, remoteStatic))
        let encryptedPayload = try state.encryptAndHash(payload)
        let (initiatorSend, initiatorReceive) = state.split()
        return (
            ephemeral + encryptedPayload,
            NoiseTransportCiphers(send: initiatorReceive, receive: initiatorSend, handshakeHash: state.handshakeHash)
        )
    }
}
