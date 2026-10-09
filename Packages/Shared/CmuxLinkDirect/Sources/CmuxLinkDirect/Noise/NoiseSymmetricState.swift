import CryptoKit
import Foundation

/// Noise SymmetricState (spec section 5.2) with SHA-256.
struct NoiseSymmetricState: Sendable {
    static let hashLength = 32

    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= Self.hashLength {
            handshakeHash = name + Data(count: Self.hashLength - name.count)
        } else {
            handshakeHash = Data(SHA256.hash(data: name))
        }
        chainingKey = handshakeHash
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (newChainingKey, tempKey) = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = newChainingKey
        cipher = NoiseCipherState(key: SymmetricKey(data: tempKey))
    }

    mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: handshakeHash)
        hasher.update(data: data)
        handshakeHash = Data(hasher.finalize())
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, associatedData: handshakeHash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, associatedData: handshakeHash)
        mixHash(ciphertext)
        return plaintext
    }

    /// The initiator's send cipher first, then its receive cipher.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (first, second) = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (NoiseCipherState(key: SymmetricKey(data: first)), NoiseCipherState(key: SymmetricKey(data: second)))
    }

    /// HKDF as Noise defines it (spec section 4.3), two outputs.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey))))
        let first = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: tempKey))
        let second = Data(HMAC<SHA256>.authenticationCode(for: first + Data([0x02]), using: tempKey))
        return (first, second)
    }
}
