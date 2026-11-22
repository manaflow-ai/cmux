import CmuxNextCompat
import Foundation
import Security

/// The keychain item embedded Chromium keeps its cookie and saved-password key in: cmux's own.
///
/// Chromium's default is the "Chromium Safe Storage" item (account "Chromium"), which every Chromium build
/// shares: Chromium.app, ungoogled-chromium, other Chromium-based apps and every cmux channel. A login-keychain item
/// trusts only the app that made it, so a cmux whose item another app made first asked on every launch "cmux NIGHTLY
/// wants to use your confidential information stored in "Chromium Safe Storage" in your keychain", and an update's
/// relaunch was such a launch (m1max, 2026-11-17: ungoogled-chromium made that item in 2021). The fork reads only the
/// item the app names (`cmux_set_keychain_item`, fork API 25): "cmux Safe Storage", one account per bundle, so each
/// channel's item is its own and a Developer ID update (same designated requirement) keeps reading it silently.
///
/// Nothing here reads another app's item with a prompt. Only the browser import does that, on the person's request,
/// where macOS's question is the consent (`CmuxNextBrowserImport.SafeStorageKeys`).
nonisolated struct CEFKeychainItem: Equatable, Sendable {
    /// The service every cmux channel's item has; the account tells the channels apart.
    static let service = "cmux Safe Storage"
    /// Chromium's shared default item (both brandings' names: the fork refuses all four as an embedder item).
    static let sharedService = "Chromium Safe Storage"
    static let sharedAccount = "Chromium"

    var service: String
    var account: String

    /// The item of the app with `bundleIdentifier` (each channel its own: NIGHTLY, RC, Release, tagged DEV builds).
    static func forApplication(bundleIdentifier: String?) -> CEFKeychainItem {
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return CEFKeychainItem(service: service, account: bundle)
    }

    /// Whether `service` or `account` names the item every Chromium build shares.
    static func isShared(service: String, account: String) -> Bool {
        let shared: Set = ["chromium safe storage", "chrome safe storage", "chromium", "chrome"]
        return shared.contains(service.lowercased()) || shared.contains(account.lowercased())
    }
}

/// The calls ``CEFKeychainMigration`` makes. None of them ever shows a keychain prompt.
nonisolated protocol CEFKeychainAccess: Sendable {
    /// Whether this user has no default keychain at all (``LoginKeychain/defaultKeychainMissing()``).
    func defaultKeychainMissing() -> Bool
    /// Whether the item exists: its attributes only, never its secret, so it never asks.
    func exists(service: String, account: String) -> Bool
    /// The item's secret, or nil when it is missing or this app is not trusted to read it without asking (the
    /// process's keychain user interaction is off for the call: `LoginKeychain.withoutUI`).
    func readWithoutUI(service: String, account: String) -> Data?
    /// Adds the item (never updates one), with no explicit access list: it trusts only this app.
    func add(service: String, account: String, secret: Data) -> OSStatus
}

/// Moves an existing profile's key into cmux's own item once, before Chromium starts, without a prompt.
///
/// A profile that ran with the shared item has cookies and saved passwords encrypted with that item's key. When this
/// app may read the shared item without asking (it made it, or the person once chose Always Allow), its own item is
/// made with the same key, so nothing is signed out. When it may not, nothing is read and nothing asks: Chromium makes
/// the own item with a new key, and what was encrypted before stays on disk unreadable (the fork keeps such cookies;
/// a site that sets them again replaces them). A fresh profile never touches the shared item at all.
nonisolated enum CEFKeychainMigration {
    enum Outcome: Equatable, Sendable {
        /// This user has no keychain (a fresh `HOME` a test or fleet job made): Chromium runs on the mock keychain,
        /// because its first `SecItemAdd` would show "Keychain Not Found" and wait for a person.
        case noKeychain
        /// The own item exists: nothing to do (every launch after the first).
        case ownItemExists
        /// No Chromium profile yet: Chromium makes the own item; the shared item is never looked at.
        case freshProfile
        /// The own item was made with the shared item's key.
        case copiedSharedKey
        /// The shared item is missing or not readable without a prompt: Chromium makes the own item with a new key.
        case sharedKeyNotReadable
        /// Adding the own item failed; Chromium tries again (add-only) when it starts.
        case addFailed(OSStatus)
    }

    /// Chromium writes `Local State` at the root cache when it first runs, so its absence means no data under any key.
    static func hasProfile(root: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: root.appending(path: "Local State").path)
    }

    static func prepare(item: CEFKeychainItem, profileRoot: URL, keychain: any CEFKeychainAccess,
                        fileManager: FileManager = .default) -> Outcome {
        if keychain.defaultKeychainMissing() { return .noKeychain }
        if keychain.exists(service: item.service, account: item.account) { return .ownItemExists }
        guard hasProfile(root: profileRoot, fileManager: fileManager) else { return .freshProfile }
        guard var secret = keychain.readWithoutUI(service: CEFKeychainItem.sharedService, account: CEFKeychainItem.sharedAccount),
              !secret.isEmpty else { return .sharedKeyNotReadable }
        defer { secret.resetBytes(in: 0 ..< secret.count) }
        let status = keychain.add(service: item.service, account: item.account, secret: secret)
        // Another cmux process made it first (errSecDuplicateItem): that one stands.
        if status == errSecSuccess || status == errSecDuplicateItem { return .copiedSharedKey }
        return .addFailed(status)
    }
}

/// The login keychain, through the app's one ``LoginKeychain`` (its user-interaction switch is process-wide).
nonisolated struct CEFLoginKeychainAccess: CEFKeychainAccess {
    let loginKeychain: LoginKeychain

    func defaultKeychainMissing() -> Bool { loginKeychain.defaultKeychainMissing() }

    func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, nil) } == errSecSuccess
    }

    func readWithoutUI(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &result) }
        return status == errSecSuccess ? result as? Data : nil
    }

    func add(service: String, account: String, secret: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: secret,
        ]
        return loginKeychain.withoutUI { SecItemAdd(attributes as CFDictionary, nil) }
    }
}
