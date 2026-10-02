import CommonCrypto
public import Foundation

/// Chromium's password encryption on macOS: the same OSCrypt scheme as its
/// cookies (`ChromiumCookieCrypto`): PBKDF2-HMAC-SHA1 of the
/// "<Name> Safe Storage" Keychain password, salt "saltysalt", 1003
/// iterations, 16 bytes; "v10" + AES-128-CBC with an IV of 16 spaces and
/// PKCS#7 padding. Login Data values have no host-hash prefix. The key and
/// every decrypted password are `SecretBytes`: they never become a `String`
/// or a `Data`.
public struct ChromiumPasswordCrypto: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// Not "v10" ("v11" is Linux, "v20" Windows app-bound; a browser with its own scheme lands here too).
        case unknownPrefix
        /// The key does not open this value.
        case undecryptable
    }

    private let key: SecretBytes

    /// Derives the key; the caller drops `safeStoragePassword` right after.
    public init(safeStoragePassword: SecretBytes) {
        key = SecretBytes(capacity: kCCKeySizeAES128) { out in
            let salt = Array("saltysalt".utf8)
            let status = safeStoragePassword.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
            precondition(status == kCCSuccess, "PBKDF2 with fixed parameters cannot fail")
            return kCCKeySizeAES128
        }
    }

    /// Decrypts one `password_value` straight into a `SecretBytes`.
    public func decrypt(_ encrypted: Data) throws(Failure) -> SecretBytes {
        let prefix = Data("v10".utf8)
        guard encrypted.starts(with: prefix) else { throw .unknownPrefix }
        return try crypt(CCOperation(kCCDecrypt), encrypted.dropFirst(prefix.count))
    }

    /// The inverse, for test fixtures only (their passwords are synthetic,
    /// so the plain copy below holds nothing real).
    public func encrypt(_ secret: SecretBytes) throws(Failure) -> Data {
        let plain = secret.withUnsafeBytes { Data($0) }
        let sealed = try crypt(CCOperation(kCCEncrypt), plain)
        return Data("v10".utf8) + sealed.withUnsafeBytes { Data($0) }
    }

    private func crypt(_ operation: CCOperation, _ input: Data) throws(Failure) -> SecretBytes {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var status = CCCryptorStatus(kCCSuccess)
        let output = SecretBytes(capacity: input.count + kCCBlockSizeAES128) { out in
            var written = 0
            status = input.withUnsafeBytes { data in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyBytes.count, iv, data.baseAddress, data.count,
                            out.baseAddress, out.count, &written)
                }
            }
            return status == kCCSuccess ? written : 0
        }
        guard status == kCCSuccess else { throw .undecryptable }
        return output
    }
}
