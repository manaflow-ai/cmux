import Foundation
import Security

protocol MobileHostIrohSecretKeyStoring: Sendable {
    func loadSecretKey() throws -> Data?
    func saveSecretKey(_ key: Data) throws
}

enum MobileHostIrohSecretKeyStoreError: Error, Equatable, Sendable {
    case invalidLength(Int)
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
}

struct MobileHostIrohSecretKeyProvider: Sendable {
    static let secretKeyLength = 32

    let store: any MobileHostIrohSecretKeyStoring
    let generate: @Sendable () throws -> Data

    func secretKey() throws -> Data {
        if let existing = try store.loadSecretKey() {
            try validate(existing)
            return existing
        }
        let generated = try generate()
        try validate(generated)
        try store.saveSecretKey(generated)
        return generated
    }

    private func validate(_ key: Data) throws {
        guard key.count == Self.secretKeyLength else {
            throw MobileHostIrohSecretKeyStoreError.invalidLength(key.count)
        }
    }
}

struct MobileHostIrohKeychainSecretStore: MobileHostIrohSecretKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "dev.cmux.mobile.iroh.endpoint",
        account: String = "mac-host-endpoint-secret-key"
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
            throw MobileHostIrohSecretKeyStoreError.keychainReadFailed(status)
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
            throw MobileHostIrohSecretKeyStoreError.keychainWriteFailed(addStatus)
        }

        let update: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw MobileHostIrohSecretKeyStoreError.keychainWriteFailed(updateStatus)
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
