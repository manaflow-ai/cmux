public import Foundation

/// Chromium's cookie encryption on macOS (`components/os_crypt/sync`,
/// `os_crypt_mac.mm`): the key is PBKDF2-HMAC-SHA1 of the Keychain item
/// "<Name> Safe Storage" with salt "saltysalt", 1003 iterations, 16 bytes;
/// values are AES-128-CBC with an IV of 16 spaces and PKCS#7 padding,
/// prefixed "v10". Since cookie DB version 24 the plaintext starts with
/// SHA-256 of the cookie's host key, which must match and is removed.
/// "v11" is Linux's prefix and "v20" is Windows' app-bound format; neither
/// is used on macOS, so both report as undecryptable.
public struct ChromiumCookieCrypto: Sendable {
    public enum Failure: Error, Equatable {
        case unknownPrefix
        case badPadding
        case hostMismatch
        case notUTF8
    }

    private let key: SecretBytes

    public init(safeStoragePassword: Data) {
        key = Self.deriveKey(safeStoragePassword)
    }

    /// The password is copied once into a ``SecretBytes``, zeroed when the key is made. A key that fails to
    /// derive is empty and never decrypts: decrypt and encrypt then throw `badPadding` instead of the process
    /// trapping.
    static func deriveKey(_ password: Data) -> SecretBytes {
        ImportCrypto.pbkdf2(.sha1, password: SecretBytes(copying: password), salt: Array("saltysalt".utf8), rounds: 1003,
                            keyLength: ImportCrypto.aes128KeySize) ?? ImportCrypto.noKey
    }

    static let iv = [UInt8](repeating: 0x20, count: ImportCrypto.Cipher.aes.blockSize)

    /// Decrypts one `encrypted_value`. `hostKey` and `databaseVersion` come
    /// from the row and the `meta` table.
    public func decrypt(_ encrypted: Data, hostKey: String, databaseVersion: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw Failure.unknownPrefix }
        var plain = try Self.crypt(.decrypt, key: key, data: encrypted.dropFirst(3))
        if databaseVersion >= 24 {
            guard plain.count >= 32, plain.prefix(32) == Self.sha256(Data(hostKey.utf8)) else { throw Failure.hostMismatch }
            plain = plain.dropFirst(32)
        }
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }

    /// The inverse, for test fixtures.
    public func encrypt(_ value: String, hostKey: String, databaseVersion: Int) throws -> Data {
        var plain = Data(value.utf8)
        if databaseVersion >= 24 { plain = Self.sha256(Data(hostKey.utf8)) + plain }
        return Data("v10".utf8) + (try Self.crypt(.encrypt, key: key, data: plain))
    }

    private static func crypt(_ operation: ImportCrypto.Operation, key: SecretBytes, data: Data) throws -> Data {
        guard let output = ImportCrypto.cbc(operation, .aes, key: key, keyLength: ImportCrypto.aes128KeySize, iv: iv, [UInt8](data))
        else { throw Failure.badPadding }
        // SAFETY: Data copies the view's count bytes while the closure runs and keeps no pointer.
        return output.withUnsafeBytes { bytes in unsafe Data(bytes) }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(ImportCrypto.sha256([UInt8](data)))
    }
}
