public import Foundation
import Security

/// Supplies a Chromium browser's "<Name> Safe Storage" password.
public protocol SafeStorageKeyProviding: Sendable {
    /// Blocks while macOS shows its Keychain prompt; call off the main thread.
    /// The password is `SecretBytes`: zeroed when the last holder lets it go.
    func password(service: String) throws(CookieImportError) -> SecretBytes
}

/// The login Keychain. Reading another app's item makes macOS ask the user
/// ("cmux wants to use your confidential information stored in "Chrome
/// Safe Storage" in your keychain"); nothing here bypasses or pre-answers
/// that prompt, and the password is never stored or logged.
public struct KeychainSafeStorage: SafeStorageKeyProviding {
    public init() {}

    public func password(service: String) throws(CookieImportError) -> SecretBytes {
        #if CMUX_NO_BROWSER_DATA_IMPORT
        // The cx-f58x notary test build reads no other browser's Keychain item
        // (nightly.yml input notary_test_without_browser_data_import).
        throw .keychainDenied(service: service)
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // Security's reply is copied once and released here; it is not ours to zero.
            guard let data = item as? Data else { throw .keyNotFound(service: service) }
            return SecretBytes(copying: data)
        case errSecItemNotFound: throw .keyNotFound(service: service)
        default: throw .keychainDenied(service: service)
        }
        #endif
    }
}
