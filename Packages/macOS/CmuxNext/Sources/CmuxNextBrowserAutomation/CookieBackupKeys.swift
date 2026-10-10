public import CryptoKit
public import Foundation
import Security

/// The key that encrypts the app's cookie backups.
public nonisolated protocol CookieBackupKeySource: Sendable {
    func key() throws(CookieBackupError) -> SymmetricKey
}

/// The key in the Keychain: one generic-password item under
/// `<bundle id>.cookie-backup-key`, made on first use from 32 random bytes,
/// accessible after first unlock on this device only (never synced).
public nonisolated struct KeychainCookieBackupKey: CookieBackupKeySource {
    public let service: String
    static let account = "key"

    public init(bundleID: String?) {
        service = "\(bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next").cookie-backup-key"
    }

    public func key() throws(CookieBackupError) -> SymmetricKey {
        if let existing = try read() { return SymmetricKey(data: existing) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = base()
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "cmux cookie backup key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return SymmetricKey(data: fresh) }
        // Another process made it first: use that one.
        if status == errSecDuplicateItem, let existing = try read() { return SymmetricKey(data: existing) }
        throw CookieBackupError("the cookie backup key could not be stored in the Keychain (status \(status))")
    }

    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    private func read() throws(CookieBackupError) -> Data? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw CookieBackupError("the cookie backup key could not be read from the Keychain (status \(status))")
        }
        return data
    }
}

#if DEBUG
/// DEBUG builds only (fleet tests with no Keychain access): the key is the
/// 32 bytes of a 0600 file, made on first use. Never compiled into Release.
public nonisolated struct FileCookieBackupKey: CookieBackupKeySource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func key() throws(CookieBackupError) -> SymmetricKey {
        if let data = FileManager.default.contents(atPath: url.path), data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: fresh, attributes: [.posixPermissions: 0o600]) else {
            throw CookieBackupError("the cookie backup key file could not be written")
        }
        return SymmetricKey(data: fresh)
    }
}
#endif
