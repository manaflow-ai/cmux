import CommonCrypto
public import Foundation

// CMUX_NO_PASSWORD_IMPORT (set only by the cx-f58x notary test build,
// nightly.yml input notary_test_without_password_import) compiles out the
// browser password readers. Default builds include them.
#if !CMUX_NO_PASSWORD_IMPORT
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
                // SAFETY: CommonCrypto reads password.count bytes of the secret's view and salt.count of
                // `salt`, and writes kCCKeySizeAES128 bytes to `out`, which holds exactly the capacity
                // asked for (SecretBytes.init). Both views are bytes, valid while these closures run;
                // Int8 and UInt8 views of bytes may alias.
                unsafe CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self),
                                            password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                            out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
            // An empty key never decrypts: decrypt and encrypt then throw
            // `undecryptable` (CCCrypt refuses the key length) instead of the process trapping.
            return status == kCCSuccess ? kCCKeySizeAES128 : 0
        }
    }

    /// Decrypts one `password_value` straight into a `SecretBytes`.
    public func decrypt(_ encrypted: Data) throws(Failure) -> SecretBytes {
        let prefix = Data("v10".utf8)
        guard encrypted.starts(with: prefix) else { throw .unknownPrefix }
        let body = encrypted.dropFirst(prefix.count)
        // Whole AES blocks only: CommonCrypto answers a cut-off block with bytes, not an error.
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { throw .undecryptable }
        let plain = try crypt(CCOperation(kCCDecrypt), body)
        // Chromium saves passwords as UTF-8; anything else is a key that happened to leave valid padding.
        guard plain.isValidUTF8 else { throw .undecryptable }
        return plain
    }

    /// The inverse, for test fixtures only (their passwords are synthetic,
    /// so the plain copy below holds nothing real).
    func encrypt(_ secret: SecretBytes) throws(Failure) -> Data {
        // SAFETY: Data copies the view's count bytes while the closure runs and keeps no pointer.
        let plain = secret.withUnsafeBytes { bytes in unsafe Data(bytes) }
        let sealed = try crypt(CCOperation(kCCEncrypt), plain)
        // SAFETY: as above, a copy made while the closure runs.
        return Data("v10".utf8) + sealed.withUnsafeBytes { bytes in unsafe Data(bytes) }
    }

    private func crypt(_ operation: CCOperation, _ input: Data) throws(Failure) -> SecretBytes {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let source = [UInt8](input)
        var status = CCCryptorStatus(kCCSuccess)
        let output = SecretBytes(capacity: source.count + kCCBlockSizeAES128) { out in
            var written = 0
            status = key.withUnsafeBytes { keyBytes in
                // SAFETY: CCCrypt reads keyBytes.count bytes of the key's view, one block of `iv` and
                // source.count bytes of `source`, and writes at most out.count bytes to `out` (the
                // capacity asked for) and that count into `written`. The views are valid while these
                // closures run; the arrays are lent for the call.
                unsafe CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                               keyBytes.baseAddress, keyBytes.count, iv, source, source.count,
                               out.baseAddress, out.count, &written)
            }
            return status == kCCSuccess ? written : 0
        }
        guard status == kCCSuccess else { throw .undecryptable }
        return output
    }
}
#endif
