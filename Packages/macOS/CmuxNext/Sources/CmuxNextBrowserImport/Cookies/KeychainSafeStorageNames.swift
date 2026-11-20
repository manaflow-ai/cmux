public import Foundation
import Security

/// Lists the login Keychain's browser storage items by name, so detection
/// finds the item of a browser the registry does not name. The query asks
/// for attributes only: no password is read and macOS shows no prompt.
public struct KeychainSafeStorageNames: Sendable {
    public init() {}

    /// Items whose service ends in " Safe Storage" (Chromium, Electron) or
    /// " Storage Key" (Helium), in Keychain order.
    public func list() -> [SafeStorageName] {
        #if CMUX_NO_BROWSER_DATA_IMPORT || CMUX_NO_SAFE_STORAGE_READ
        // The cx-f58x notary test builds look up no other browser's Keychain item.
        return []
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, Self.isStorageService(service) else { return nil }
            let account = (row[kSecAttrAccount as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SafeStorageName(service: service, account: account)
        }
        #endif
    }

    /// Whether `service` names a browser storage key item.
    static func isStorageService(_ service: String) -> Bool {
        service.hasSuffix(" Safe Storage") || service.hasSuffix(" Storage Key")
    }
}
