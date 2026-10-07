import CryptoKit
import Foundation

/// ChaCha20-Poly1305 with WireGuard's nonce: 32 zero bits then the 64-bit
/// little-endian counter. Output is ciphertext followed by the 16-byte tag.
struct WireGuardAEAD {
    static let tagLength = 16

    let key: SymmetricKey

    init(key: [UInt8]) {
        self.key = SymmetricKey(data: key)
    }

    func seal(_ plaintext: some DataProtocol, counter: UInt64, authenticating aad: [UInt8] = []) throws -> [UInt8] {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try Self.nonce(counter), authenticating: aad)
        return [UInt8](box.ciphertext) + [UInt8](box.tag)
    }

    func open(_ sealed: some Collection<UInt8>, counter: UInt64, authenticating aad: [UInt8] = []) throws -> [UInt8] {
        guard sealed.count >= Self.tagLength else { throw WireGuardTunnelError.decryptFailed }
        let bytes = [UInt8](sealed)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(counter),
                ciphertext: bytes.prefix(bytes.count - Self.tagLength),
                tag: bytes.suffix(Self.tagLength)
            )
            return [UInt8](try ChaChaPoly.open(box, using: key, authenticating: aad))
        } catch {
            throw WireGuardTunnelError.decryptFailed
        }
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { bytes[4 + index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
