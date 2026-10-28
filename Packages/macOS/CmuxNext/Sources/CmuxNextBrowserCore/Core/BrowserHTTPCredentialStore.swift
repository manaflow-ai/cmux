import CmuxNextCompat
package import Foundation
package import Security

/// HTTP sign-ins the user checked "Remember password" for. Nothing goes in
/// unless they did; an off-the-record profile never reads or writes it.
package nonisolated protocol BrowserHTTPCredentialStoring: Sendable {
    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin?
    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey)
    func forget(_ key: BrowserHTTPCredentialKey)
    /// The accounts (``BrowserHTTPCredentialKey/account``) of every remembered sign-in, no secret; nil when
    /// the list cannot be read.
    func rememberedAccounts() -> Set<String>?
}

/// One generic-password item per sign-in under `<bundle id>.browser-http-auth`,
/// accessible after first unlock, this device only. Blocking Keychain calls:
/// callers run it off the main actor.
package nonisolated struct KeychainHTTPCredentialStore: BrowserHTTPCredentialStoring {
    package let service: String

    package static var standard: KeychainHTTPCredentialStore {
        KeychainHTTPCredentialStore(service: "\(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app").browser-http-auth")
    }

    private func base(_ key: BrowserHTTPCredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.account]
    }

    package func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard blockingSecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().blockingDecode(BrowserHTTPRememberedLogin.self, from: data)
    }

    package func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        if blockingSecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux sign-in for \(key.host)"
            _ = blockingSecItemAdd(add as CFDictionary, nil)
        }
    }

    package func forget(_ key: BrowserHTTPCredentialKey) {
        _ = blockingSecItemDelete(base(key) as CFDictionary)
    }

    /// Lists the items' account attributes only: reading no secret, it raises no Keychain access prompt.
    package func rememberedAccounts() -> Set<String>? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = blockingSecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    package init(service: String) {
        self.service = service
    }
}

