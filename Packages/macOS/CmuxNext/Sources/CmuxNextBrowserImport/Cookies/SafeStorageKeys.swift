public import Foundation
#if canImport(Security)
import Security
#endif

/// Supplies a Chromium browser's "<Name> Safe Storage" password.
public protocol SafeStorageKeyProviding: Sendable {
    /// Blocks while macOS shows its Keychain prompt; call off the main thread.
    /// The password is `SecretBytes`: zeroed when the last holder lets it go.
    func password(service: String) throws(CookieImportError) -> SecretBytes
}

#if canImport(Security)
/// The login Keychain. Reading another app's item makes macOS ask the user
/// ("cmux wants to use your confidential information stored in "Chrome
/// Safe Storage" in your keychain"); nothing here bypasses or pre-answers
/// that prompt, and the password is never stored or logged.
public struct KeychainSafeStorage: SafeStorageKeyProviding {
    public init() {}

    public func password(service: String) throws(CookieImportError) -> SecretBytes {
        #if CMUX_NO_BROWSER_DATA_IMPORT || CMUX_NO_SAFE_STORAGE_READ
        // The cx-f58x notary test builds read no other browser's Keychain item
        // (nightly.yml inputs notary_test_without_browser_data_import and
        // notary_test_import_part=safe-storage).
        throw .keychainDenied(service: service)
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        // SAFETY: SecItemCopyMatching stores at most one +1 CFTypeRef in the local `item`, live for the
        // call; the Swift import takes ownership of it.
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &item)
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
#endif

/// The Safe Storage keys of the system this runs on: the login Keychain on macOS, none on Linux, where Chromium
/// keeps its "v11" key in the Secret Service, which this import does not read (every read is `keyNotFound`).
struct SystemSafeStorage: SafeStorageKeyProviding {
    func password(service: String) throws(CookieImportError) -> SecretBytes {
        #if canImport(Security)
        try KeychainSafeStorage().password(service: service)
        #else
        throw .keyNotFound(service: service)
        #endif
    }
}
