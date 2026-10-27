import Foundation

/// The symmetric primitives browser import needs (Chromium's OSCrypt scheme and Firefox's NSS one) behind one
/// interface, as Chromium keeps `crypto/aes_cbc.h`, `crypto/kdf.h` and `crypto/hmac.h` over one library on every
/// OS. `ImportCrypto+CommonCrypto.swift` is the Apple implementation; `ImportCrypto+SwiftCrypto.swift` is the
/// Linux one (swift-crypto over BoringSSL), which has no 3DES (``supports(_:)``). Keys and plaintexts are
/// ``SecretBytes`` in and out.
enum ImportCrypto {
    enum PRF: Sendable {
        case sha1
        case sha256
    }

    enum Cipher: Sendable {
        case aes
        case tripleDES

        var blockSize: Int {
            switch self {
            case .aes: 16
            case .tripleDES: 8
            }
        }
    }

    enum Operation: Sendable {
        case encrypt
        case decrypt
    }

    /// One part of a hash's input: plain bytes, or a secret read in place.
    enum Piece {
        case bytes([UInt8])
        case secret(SecretBytes)
    }

    static let aes128KeySize = 16
    static let aes256KeySize = 32
    static let tripleDESKeySize = 24
    static let sha1DigestSize = 20

    /// PBKDF2 of `password` into a new `keyLength`-byte key; nil when the library refuses.
    static func pbkdf2(_ prf: PRF, password: SecretBytes, salt: [UInt8], rounds: Int, keyLength: Int) -> SecretBytes? {
        guard keyLength > 0, let rounds = UInt32(exactly: rounds), rounds > 0 else { return nil }
        return platformPBKDF2(prf, password: password, salt: salt, rounds: rounds, keyLength: keyLength)
    }

    /// CBC with PKCS#7 padding under the first `keyLength` bytes of `key`; nil when the key, the IV or the
    /// padding is wrong, the cipher is not supported here, or a decrypt's input is not whole blocks
    /// (CommonCrypto answers a cut-off block with bytes, not an error).
    static func cbc(_ operation: Operation, _ cipher: Cipher, key: SecretBytes, keyLength: Int, iv: [UInt8],
                    _ input: [UInt8]) -> SecretBytes? {
        guard supports(cipher), keyLength > 0, key.count >= keyLength, iv.count == cipher.blockSize else { return nil }
        if operation == .decrypt {
            guard !input.isEmpty, input.count % cipher.blockSize == 0 else { return nil }
        }
        return platformCBC(operation, cipher, key: key, keyLength: keyLength, iv: iv, input)
    }

    /// A key that never decrypts: ``cbc(_:_:key:keyLength:iv:_:)`` refuses its length.
    static var noKey: SecretBytes { SecretBytes(capacity: 0) { _ in 0 } }
}
