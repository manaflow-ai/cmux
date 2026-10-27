#if !canImport(CommonCrypto)
import Crypto
import _CryptoExtras
import Foundation

/// ``ImportCrypto`` where there is no CommonCrypto (the Linux tier): swift-crypto, over the BoringSSL Chromium
/// uses on every OS. swift-crypto has no 3DES, so a Firefox profile sealed with it reads as an unsupported
/// scheme here. Its results arrive as `Data` or keys, which are copied into ``SecretBytes`` and zeroed.
extension ImportCrypto {
    static func supports(_ cipher: Cipher) -> Bool { cipher == .aes }

    static func platformPBKDF2(_ prf: PRF, password: SecretBytes, salt: [UInt8], rounds: UInt32, keyLength: Int) -> SecretBytes? {
        let function: KDF.Insecure.PBKDF2.HashFunction = switch prf {
        case .sha1: .insecureSHA1
        case .sha256: .sha256
        }
        let derived: SymmetricKey? = password.withUnsafeBytes { raw in
            // SAFETY: swift-crypto reads raw.count bytes of the password's view, valid while this closure runs,
            // and keeps no pointer to it.
            try? unsafe KDF.Insecure.PBKDF2.deriveKey(from: raw, salt: salt, using: function, outputByteCount: keyLength,
                                                      unsafeUncheckedRounds: Int(rounds))
        }
        guard let derived, derived.bitCount == keyLength * 8 else { return nil }
        return secret(copying: derived)
    }

    static func platformCBC(_ operation: Operation, _ cipher: Cipher, key: SecretBytes, keyLength: Int, iv: [UInt8],
                            _ input: [UInt8]) -> SecretBytes? {
        guard cipher == .aes, let vector = try? AES._CBC.IV(ivBytes: iv) else { return nil }
        let result: Data? = key.withUnsafeBytes { raw in
            // SAFETY: cbc checked key.count >= keyLength, so the slice is inside the key's view; SymmetricKey
            // copies those bytes while this closure runs.
            let symmetric = unsafe SymmetricKey(data: UnsafeRawBufferPointer(rebasing: raw[0..<keyLength]))
            switch operation {
            case .encrypt: return try? AES._CBC.encrypt(input, using: symmetric, iv: vector)
            case .decrypt: return try? AES._CBC.decrypt(input, using: symmetric, iv: vector)
            }
        }
        guard var result else { return nil }
        defer { result.resetBytes(in: 0..<result.count) }
        return secret(copying: result)
    }

    /// SHA-1 of the pieces in order.
    static func sha1(_ pieces: [Piece]) -> SecretBytes {
        var hasher = Insecure.SHA1()
        for piece in pieces {
            switch piece {
            case .bytes(let bytes): hasher.update(data: bytes)
            case .secret(let secret):
                // SAFETY: the hasher reads the secret's view while this closure runs and keeps no pointer to it.
                secret.withUnsafeBytes { raw in unsafe hasher.update(bufferPointer: raw) }
            }
        }
        return secret(copying: hasher.finalize())
    }

    /// HMAC-SHA1 under `key` of the pieces in order.
    static func hmacSHA1(key: SecretBytes, _ pieces: [Piece]) -> SecretBytes {
        // SAFETY: SymmetricKey copies the key's view while this closure runs.
        let symmetric = key.withUnsafeBytes { raw in unsafe SymmetricKey(data: raw) }
        var mac = HMAC<Insecure.SHA1>(key: symmetric)
        for piece in pieces {
            switch piece {
            case .bytes(let bytes): mac.update(data: bytes)
            case .secret(let secret):
                // SAFETY: the MAC reads the secret's view while this closure runs and keeps no pointer to it.
                secret.withUnsafeBytes { raw in unsafe mac.update(data: raw) }
            }
        }
        return secret(copying: mac.finalize())
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    /// A ``SecretBytes`` copy of `bytes` (a digest, a MAC, a key or a plaintext from swift-crypto).
    private static func secret(copying bytes: some ContiguousBytes) -> SecretBytes {
        // SAFETY: the new buffer holds max(raw.count, 1) bytes, room for the raw.count copied in from a view
        // valid while this closure runs.
        unsafe bytes.withUnsafeBytes { raw in
            SecretBytes(capacity: raw.count) { out in
                unsafe out.copyMemory(from: raw)
                return raw.count
            }
        }
    }
}
#endif
