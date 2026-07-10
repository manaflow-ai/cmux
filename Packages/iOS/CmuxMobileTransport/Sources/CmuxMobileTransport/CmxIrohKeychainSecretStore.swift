import Foundation
import Security

struct CmxIrohKeychainSecretStore: CmxIrohSecretKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "dev.cmux.mobile.iroh.endpoint",
        account: String = "phone-endpoint-secret-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadSecretKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CmxIrohSecretKeyStoreError.keychainReadFailed(status)
        }
        return data
    }

    func saveSecretKey(_ key: Data) throws {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            throw CmxIrohSecretKeyStoreError.keychainWriteFailed(addStatus)
        }

        let update: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw CmxIrohSecretKeyStoreError.keychainWriteFailed(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
