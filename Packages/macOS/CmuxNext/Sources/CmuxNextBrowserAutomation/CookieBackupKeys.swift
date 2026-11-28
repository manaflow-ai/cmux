public import CmuxNextCompat
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
    /// The app's one guard of the Keychain UI switch.
    let loginKeychain: LoginKeychain

    public init(bundleID: String?, loginKeychain: LoginKeychain) {
        service = "\(bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next").cookie-backup-key"
        self.loginKeychain = loginKeychain
    }

    public func key() throws(CookieBackupError) -> SymmetricKey {
        if let existing = try read() { return SymmetricKey(data: existing) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = base()
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "cmux cookie backup key"
        let status = loginKeychain.withoutUI { SecItemAdd(add as CFDictionary, nil) }
        if try CookieBackupKeyRules.addStep(status) == "useFresh" { return SymmetricKey(data: fresh) }
        // Another process made it first: use that one.
        if let existing = try read() { return SymmetricKey(data: existing) }
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
        // No UI: an item another signature of this bundle id made is refused, never prompted for.
        let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &result) }
        let data = result as? Data
        guard try CookieBackupKeyRules.readFound(status, length: data?.count), let data else { return nil }
        return data
    }
}

/// What the Keychain's and the key file's answers mean: Rust's (cmux-browser-rules
/// `page_events.rs`, ops `browser_rules_automation_cookie_backup_key_*`). Swift makes
/// the Keychain calls, the 32 random bytes and the file; Rust reads their answers.
nonisolated enum CookieBackupKeyRules {
    /// The library always answers; only an app FFI pin behind the Rust lacks the ops.
    private static let silent = CookieBackupError("the cookie backup key rules did not answer (app FFI pin behind cmux-browser-rules)")

    private static func ask(_ op: String, _ request: [String: Any], _ field: String) throws(CookieBackupError) -> DriverJSON {
        guard case .object(let reply)? = BrowserRulesFFI.call(op, request) else { throw silent }
        if let error = reply["error"]?.stringValue { throw CookieBackupError(error) }
        guard let value = reply[field] else { throw silent }
        return value
    }

    /// Whether a Keychain read found the key (false: none yet, make one); throws its error text.
    static func readFound(_ status: OSStatus, length: Int?) throws(CookieBackupError) -> Bool {
        var request: [String: Any] = ["status": Int(status)]
        if let length { request["length"] = length }
        return try ask("cookie_backup_key_read", request, "found").boolValue ?? false
    }

    /// The step after `SecItemAdd` answered `status`: `useFresh` or `readExisting`; throws its error text.
    static func addStep(_ status: OSStatus) throws(CookieBackupError) -> String {
        try ask("cookie_backup_key_add", ["status": Int(status)], "step").stringValue ?? ""
    }

    /// Whether the DEBUG key file's contents are the key.
    static func fileUsable(length: Int) -> Bool {
        BrowserRulesFFI.call("cookie_backup_key_file", ["length": length])?.boolValue ?? false
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
        if let data = FileManager.default.contents(atPath: url.path), CookieBackupKeyRules.fileUsable(length: data.count) { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: fresh, attributes: [.posixPermissions: 0o600]) else {
            throw CookieBackupError("the cookie backup key file could not be written")
        }
        return SymmetricKey(data: fresh)
    }
}
#endif
