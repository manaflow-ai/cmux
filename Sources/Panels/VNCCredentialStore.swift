import Foundation
import LocalAuthentication
import Security

/// Stores VNC passwords and gates retrieval behind Touch ID.
///
/// The secret is kept in the login Keychain (per bundle id), falling back to a
/// `0600` file when the Keychain is unavailable (ad-hoc Debug builds without a
/// matching `keychain-access-groups` entitlement return `errSecMissingEntitlement`).
/// Either way, reads go through `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`,
/// so a password only leaves storage after a successful Touch ID (or device
/// passcode) check. This needs no special entitlement, so it works on dev builds.
enum VNCCredentialStore {
    private static var service: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return "\(bundle).vnc"
    }

    private static func account(host: String, port: UInt16) -> String {
        "\(host):\(port)"
    }

    // MARK: - Existence (no prompt)

    /// Whether a password is stored for `host:port`, without prompting.
    static func hasCredential(host: String, port: UInt16) -> Bool {
        if keychainReadData(account: account(host: host, port: port), prompt: false) != nil {
            return true
        }
        return fileRead()[account(host: host, port: port)] != nil
    }

    // MARK: - Save (no prompt)

    static func save(host: String, port: UInt16, password: String) {
        let acct = account(host: host, port: port)
        if keychainWrite(password, account: acct) { return }
        // Keychain unavailable: fall back to a 0600 file.
        var map = fileRead()
        map[acct] = password
        fileWrite(map)
    }

    // MARK: - Load (Touch ID gated)

    /// Returns the stored password after a Touch ID / passcode check, or `nil`
    /// if the user cancels, biometrics fail, or nothing is stored.
    static func load(host: String, port: UInt16, reason: String) async -> String? {
        let acct = account(host: host, port: port)
        guard hasCredential(host: host, port: port) else { return nil }

        let context = LAContext()
        var policyError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            // No biometrics/passcode available at all; do not silently release.
            return nil
        }
        let authorized: Bool = await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard authorized else { return nil }

        if let data = keychainReadData(account: acct, prompt: false),
           let password = String(data: data, encoding: .utf8) {
            return password
        }
        return fileRead()[acct]
    }

    // MARK: - Delete

    static func delete(host: String, port: UInt16) {
        let acct = account(host: host, port: port)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)
        var map = fileRead()
        if map.removeValue(forKey: acct) != nil {
            fileWrite(map)
        }
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainReadData(account: String, prompt: Bool) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !prompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let lookup = baseQuery(account: account)
        let updateStatus = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }
        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - File fallback

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return base.appendingPathComponent("cmux/\(bundle)/vnc-credentials.json")
    }

    private static func fileRead() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func fileWrite(_ map: [String: String]) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Best effort; storage is optional.
        }
    }
}
