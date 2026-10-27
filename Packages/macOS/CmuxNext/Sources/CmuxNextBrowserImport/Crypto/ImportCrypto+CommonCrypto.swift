#if canImport(CommonCrypto)
import CommonCrypto
import Foundation

/// ``ImportCrypto`` on Apple platforms: CommonCrypto, reading and writing the secrets' own buffers, so a key or a
/// plaintext is never copied out of its ``SecretBytes``.
extension ImportCrypto {
    static func supports(_ cipher: Cipher) -> Bool { true }

    static func platformPBKDF2(_ prf: PRF, password: SecretBytes, salt: [UInt8], rounds: UInt32, keyLength: Int) -> SecretBytes? {
        let algorithm = switch prf {
        case .sha1: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case .sha256: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }
        let key = SecretBytes(capacity: keyLength) { out in
            let status = password.withUnsafeBytes { raw in
                // SAFETY: CommonCrypto reads raw.count bytes of the password's view and salt.count of `salt`, and
                // writes keyLength bytes to `out`, which holds exactly the capacity asked for (SecretBytes.init).
                // Both views are bytes, valid while these closures run; Int8 and UInt8 views of bytes may alias.
                unsafe CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.baseAddress?.assumingMemoryBound(to: Int8.self),
                                            raw.count, salt, salt.count, algorithm, rounds,
                                            out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
            }
            return status == kCCSuccess ? keyLength : 0
        }
        return key.count == keyLength ? key : nil
    }

    static func platformCBC(_ operation: Operation, _ cipher: Cipher, key: SecretBytes, keyLength: Int, iv: [UInt8],
                            _ input: [UInt8]) -> SecretBytes? {
        let algorithm = switch cipher {
        case .aes: CCAlgorithm(kCCAlgorithmAES)
        case .tripleDES: CCAlgorithm(kCCAlgorithm3DES)
        }
        let direction = operation == .encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        var status = CCCryptorStatus(kCCSuccess)
        let output = SecretBytes(capacity: input.count + cipher.blockSize) { out in
            var written = 0
            status = key.withUnsafeBytes { keyBytes in
                // SAFETY: CCCrypt reads keyLength bytes of the key's view (cbc checked key.count >= keyLength), one
                // block of `iv` (checked) and input.count bytes of `input`, and writes at most out.count bytes to
                // `out` (the capacity asked for) and that count into `written`. The views are valid while these
                // closures run; the arrays are lent for the call.
                unsafe CCCrypt(direction, algorithm, CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, keyLength, iv,
                               input, input.count, out.baseAddress, out.count, &written)
            }
            return status == kCCSuccess ? written : 0
        }
        return status == kCCSuccess ? output : nil
    }

    /// SHA-1 of the pieces in order; the running state is zeroed after.
    static func sha1(_ pieces: [Piece]) -> SecretBytes {
        SecretBytes(capacity: sha1DigestSize) { out in
            var context = CC_SHA1_CTX()
            // SAFETY: each call below gets the local `context`, live for the call, and reads bytes.count bytes of
            // each array or secret view, lent for the call.
            _ = unsafe CC_SHA1_Init(&context)
            for piece in pieces {
                switch piece {
                case .bytes(let bytes):
                    _ = unsafe CC_SHA1_Update(&context, bytes, CC_LONG(bytes.count))
                case .secret(let secret):
                    secret.withUnsafeBytes { raw in
                        // SAFETY: reads raw.count bytes of the secret's view, valid while this closure runs.
                        _ = unsafe CC_SHA1_Update(&context, raw.baseAddress, CC_LONG(raw.count))
                    }
                }
            }
            // SAFETY: reads the lent buffer's count, not its bytes.
            guard unsafe out.count >= sha1DigestSize else { return 0 }
            // SAFETY: CC_SHA1_Final writes sha1DigestSize bytes, inside `out` (checked above), and reads `context`;
            // memset_s zeroes exactly the context's own size. Both pointers are live for their calls.
            _ = unsafe CC_SHA1_Final(out.baseAddress?.assumingMemoryBound(to: UInt8.self), &context)
            _ = unsafe memset_s(&context, MemoryLayout<CC_SHA1_CTX>.size, 0, MemoryLayout<CC_SHA1_CTX>.size)
            return sha1DigestSize
        }
    }

    /// HMAC-SHA1 under `key` of the pieces in order; the running state is zeroed after.
    static func hmacSHA1(key: SecretBytes, _ pieces: [Piece]) -> SecretBytes {
        SecretBytes(capacity: sha1DigestSize) { out in
            var context = CCHmacContext()
            key.withUnsafeBytes { keyBytes in
                // SAFETY: reads keyBytes.count bytes of the key's view, valid while this closure runs, into the local
                // `context`.
                unsafe CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, keyBytes.count)
            }
            for piece in pieces {
                switch piece {
                case .bytes(let bytes):
                    // SAFETY: reads bytes.count bytes of the array lent for the call into the local `context`.
                    unsafe CCHmacUpdate(&context, bytes, bytes.count)
                case .secret(let secret):
                    secret.withUnsafeBytes { raw in
                        // SAFETY: reads raw.count bytes of the secret's view, valid while this closure runs.
                        unsafe CCHmacUpdate(&context, raw.baseAddress, raw.count)
                    }
                }
            }
            // SAFETY: reads the lent buffer's count, not its bytes.
            guard unsafe out.count >= sha1DigestSize else { return 0 }
            // SAFETY: writes the 20-byte digest to `out` (checked above), then zeroes exactly the local context's size.
            unsafe CCHmacFinal(&context, out.baseAddress)
            _ = unsafe memset_s(&context, MemoryLayout<CCHmacContext>.size, 0, MemoryLayout<CCHmacContext>.size)
            return sha1DigestSize
        }
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        // SAFETY: CC_SHA256 reads bytes.count bytes of `bytes` and writes CC_SHA256_DIGEST_LENGTH (digest.count)
        // bytes into `digest`; both are lent for the call, and the returned pointer (to `digest`) is dropped unread.
        _ = unsafe CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest
    }
}
#endif
