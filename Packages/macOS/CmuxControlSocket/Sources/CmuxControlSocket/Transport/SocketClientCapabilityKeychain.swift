internal import Foundation
#if canImport(Security)
internal import Security
#endif

/// Data Protection Keychain adapter for one capability-secret identity.
struct SocketClientCapabilityKeychain: Sendable {
    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func readSecret() -> Data? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
#else
        return nil
#endif
    }

    func writeSecret(_ secret: Data) -> Bool {
#if canImport(Security)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: secret] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = identity
        insertion[kSecValueData] = secret
        insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(
                identity as CFDictionary,
                [kSecValueData: secret] as CFDictionary
            ) == errSecSuccess
        }
        return addStatus == errSecSuccess
#else
        return false
#endif
    }
}
