import CommonCrypto
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

    private let key: Data

    public init(safeStoragePassword: Data) {
        key = Self.deriveKey(safeStoragePassword)
    }

    static func deriveKey(_ password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        // An empty key never decrypts: decrypt and encrypt then throw `badPadding`
        // (CCCrypt refuses the key length) instead of the process trapping.
        guard status == kCCSuccess else { return Data() }
        return Data(key)
    }

    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// Decrypts one `encrypted_value`. `hostKey` and `databaseVersion` come
    /// from the row and the `meta` table.
    public func decrypt(_ encrypted: Data, hostKey: String, databaseVersion: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw Failure.unknownPrefix }
        var plain = try Self.crypt(CCOperation(kCCDecrypt), key: key, data: encrypted.dropFirst(3))
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
        return Data("v10".utf8) + (try Self.crypt(CCOperation(kCCEncrypt), key: key, data: plain))
    }

    private static func crypt(_ operation: CCOperation, key: Data, data: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.badPadding }
        return output.prefix(written)
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
}
