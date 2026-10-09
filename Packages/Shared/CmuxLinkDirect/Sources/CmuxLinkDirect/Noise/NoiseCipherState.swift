import CryptoKit
import Foundation

/// Noise CipherState (spec section 5.1) for ChaChaPoly: a key and a 64-bit
/// counter nonce, encoded as 32 zero bits then the counter little-endian.
struct NoiseCipherState: Sendable {
    static let tagLength = 16
    static let maxMessageLength = 65_535

    private var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    mutating func encrypt(_ plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        guard plaintext.count + Self.tagLength <= Self.maxMessageLength else { throw NoiseError.messageTooLarge }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try nextNonce(), authenticating: associatedData)
        return box.ciphertext + box.tag
    }

    mutating func decrypt(_ ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= Self.tagLength else { throw NoiseError.decryptionFailed }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -Self.tagLength)
        let nonce = try currentNonce()
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext[..<split], tag: ciphertext[split...])
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: associatedData)
            self.nonce += 1
            return plaintext
        } catch {
            throw NoiseError.decryptionFailed
        }
    }

    private func currentNonce() throws -> ChaChaPoly.Nonce {
        // 2^64-1 is reserved (spec 5.1).
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        var bytes = Data(count: 4)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        let value = try currentNonce()
        nonce += 1
        return value
    }
}
