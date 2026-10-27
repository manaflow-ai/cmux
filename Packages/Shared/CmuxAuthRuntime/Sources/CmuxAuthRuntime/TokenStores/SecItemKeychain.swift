#if canImport(Security)
import func CmuxThreading.blockingCall
import Foundation
import Security

/// The system Keychain through `SecItem`. Each call waits for securityd, so it runs as a checked blocking call.
struct SecItemKeychain: KeychainItemStoring {
    /// The accessibility every item the store writes or hardens gets.
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    func copyData(_ item: KeychainItemAddress) -> (status: KeychainItemStatus, data: Data?) {
        var query = Self.query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = Self.status(blockingCall(.systemCall) { SecItemCopyMatching(query as CFDictionary, &result) })
        guard status == .success, let data = result as? Data else {
            return (status == .success ? .itemNotFound : status, nil)
        }
        return (.success, data)
    }

    func update(_ item: KeychainItemAddress, data: Data?) -> KeychainItemStatus {
        var attributes: [String: Any] = [kSecAttrAccessible as String: Self.accessibility]
        if let data {
            attributes[kSecValueData as String] = data
        }
        let query = Self.query(item)
        return Self.status(blockingCall(.systemCall) {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        })
    }

    func add(_ item: KeychainItemAddress, data: Data) -> KeychainItemStatus {
        var insert = Self.query(item)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = Self.accessibility
        return Self.status(blockingCall(.systemCall) { SecItemAdd(insert as CFDictionary, nil) })
    }

    func delete(_ item: KeychainItemAddress) -> KeychainItemStatus {
        let query = Self.query(item)
        return Self.status(blockingCall(.systemCall) { SecItemDelete(query as CFDictionary) })
    }

    private static func query(_ item: KeychainItemAddress) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // An omitted service would be a wildcard, so the legacy items' empty service is spelled out.
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        if item.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessGroup = item.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func status(_ status: OSStatus) -> KeychainItemStatus {
        switch status {
        case errSecSuccess: .success
        case errSecItemNotFound: .itemNotFound
        default: .failed(status)
        }
    }
}
#endif
