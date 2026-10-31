package import Foundation
package import Security

/// HTTP sign-ins the user checked "Remember password" for. Nothing goes in
/// unless they did; an off-the-record profile never reads or writes it.
package nonisolated protocol BrowserHTTPCredentialStoring: Sendable {
    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin?
    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey)
    func forget(_ key: BrowserHTTPCredentialKey)
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BrowserHTTPRememberedLogin.self, from: data)
    }

    package func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        if SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux sign-in for \(key.host)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    package func forget(_ key: BrowserHTTPCredentialKey) {
        SecItemDelete(base(key) as CFDictionary)
    }

    package init(service: String) {
        self.service = service
    }
}

