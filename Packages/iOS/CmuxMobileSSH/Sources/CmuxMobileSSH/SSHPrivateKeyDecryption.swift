import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Decrypts the private section of a passphrase-protected OpenSSH key.
///
/// The key and IV come from `bcrypt_pbkdf(passphrase, salt, rounds)` over
/// `keyLength + ivLength` bytes (key first). A wrong passphrase yields garbage
/// plaintext; the parser detects it through the checkint mismatch.
///
/// `aes256-gcm@openssh.com` is not supported: its 16-byte tag follows the
/// private blob in the file and the parser only hands over the blob itself.
enum SSHPrivateKeyDecryption {
    private struct CipherSpec {
        var keyLength: Int
        var ivLength: Int
        var blockSize: Int
        var isCTR: Bool
    }

    private static func spec(for cipher: String) -> CipherSpec? {
        switch cipher {
        case "aes256-ctr": CipherSpec(keyLength: 32, ivLength: 16, blockSize: 16, isCTR: true)
        case "aes192-ctr": CipherSpec(keyLength: 24, ivLength: 16, blockSize: 16, isCTR: true)
        case "aes128-ctr": CipherSpec(keyLength: 16, ivLength: 16, blockSize: 16, isCTR: true)
        case "aes256-cbc": CipherSpec(keyLength: 32, ivLength: 16, blockSize: 16, isCTR: false)
        case "aes192-cbc": CipherSpec(keyLength: 24, ivLength: 16, blockSize: 16, isCTR: false)
        case "aes128-cbc": CipherSpec(keyLength: 16, ivLength: 16, blockSize: 16, isCTR: false)
        default: nil
        }
    }

    static func decrypt(_ blob: [UInt8], cipher: String, kdfOptions: [UInt8], passphrase: String) throws -> [UInt8] {
        guard let spec = spec(for: cipher) else { throw SSHPrivateKeyParseError.unsupportedCipher(cipher) }
        var options = SSHWireReader(kdfOptions)
        let salt = try options.readBytes()
        let rounds = try options.readUInt32()
        guard rounds >= 1, rounds <= 1 << 20, !salt.isEmpty else { throw SSHPrivateKeyParseError.malformed }
        guard !blob.isEmpty, blob.count % spec.blockSize == 0 else { throw SSHPrivateKeyParseError.malformed }

        let derived = BcryptPBKDF.derive(
            password: Array(passphrase.utf8),
            salt: salt,
            keyLength: spec.keyLength + spec.ivLength,
            rounds: Int(rounds)
        )
        let key = Array(derived[0..<spec.keyLength])
        let iv = Array(derived[spec.keyLength...])
        return try aesDecrypt(blob, key: key, iv: iv, ctr: spec.isCTR, cipherName: cipher)
    }

    private static func aesDecrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8], ctr: Bool, cipherName: String) throws -> [UInt8] {
        #if canImport(CommonCrypto)
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(ctr ? kCCModeCTR : kCCModeCBC),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    ctr ? CCModeOptions(kCCModeOptionCTR_BE) : 0,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw SSHPrivateKeyParseError.malformed }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, input.count, outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw SSHPrivateKeyParseError.malformed }
        return output
        #else
        throw SSHPrivateKeyParseError.unsupportedCipher(cipherName)
        #endif
    }
}
