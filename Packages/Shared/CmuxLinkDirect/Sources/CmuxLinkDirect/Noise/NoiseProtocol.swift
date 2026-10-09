import CryptoKit
import Foundation

/// `Noise_IK_25519_ChaChaPoly_SHA256` constants and the X25519 step both
/// roles share.
struct NoiseProtocol: Sendable {
    let name = "Noise_IK_25519_ChaChaPoly_SHA256"
    let keyLength = 32

    /// The symmetric state after the prologue and the responder's static
    /// key (the IK pre-message `<- s`).
    func initialState(prologue: Data, responderStatic: Data) -> NoiseSymmetricState {
        var state = NoiseSymmetricState(protocolName: name)
        state.mixHash(prologue)
        state.mixHash(responderStatic)
        return state
    }

    func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
        do {
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.invalidKey
        }
    }
}
