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

    /// Derives the key; the caller drops `safeStoragePassword` right after. A key that fails to derive is empty
    /// and never decrypts: decrypt and encrypt then throw `undecryptable` instead of the process trapping.
    public init(safeStoragePassword: SecretBytes) {
        key = ImportCrypto.pbkdf2(.sha1, password: safeStoragePassword, salt: Array("saltysalt".utf8), rounds: 1003,
                                  keyLength: ImportCrypto.aes128KeySize) ?? ImportCrypto.noKey
    }

    /// Decrypts one `password_value` straight into a `SecretBytes`.
    public func decrypt(_ encrypted: Data) throws(Failure) -> SecretBytes {
        let prefix = Data("v10".utf8)
        guard encrypted.starts(with: prefix) else { throw .unknownPrefix }
        let body = encrypted.dropFirst(prefix.count)
        let plain = try crypt(.decrypt, body)
        // Chromium saves passwords as UTF-8; anything else is a key that happened to leave valid padding.
        guard plain.isValidUTF8 else { throw .undecryptable }
        return plain
    }

    /// The inverse, for test fixtures only (their passwords are synthetic,
    /// so the plain copy below holds nothing real).
    func encrypt(_ secret: SecretBytes) throws(Failure) -> Data {
        // SAFETY: Data copies the view's count bytes while the closure runs and keeps no pointer.
        let plain = secret.withUnsafeBytes { bytes in unsafe Data(bytes) }
        let sealed = try crypt(.encrypt, plain)
        // SAFETY: as above, a copy made while the closure runs.
        return Data("v10".utf8) + sealed.withUnsafeBytes { bytes in unsafe Data(bytes) }
    }

    /// AES-128-CBC with an IV of 16 spaces; whole blocks only on decrypt (``ImportCrypto/cbc(_:_:key:keyLength:iv:_:)``).
    private func crypt(_ operation: ImportCrypto.Operation, _ input: Data) throws(Failure) -> SecretBytes {
        let iv = [UInt8](repeating: 0x20, count: ImportCrypto.Cipher.aes.blockSize)
        guard let output = ImportCrypto.cbc(operation, .aes, key: key, keyLength: ImportCrypto.aes128KeySize, iv: iv, [UInt8](input))
        else { throw .undecryptable }
        return output
    }
}
#endif
