import Foundation
import Security

/// Where vault values and their authoritative scopes live (the seam tests replace with memory).
nonisolated protocol CredentialVaultSecretStoring: Sendable {
    func save(_ record: CredentialVaultSecretRecord, for name: String) throws
    func record(for name: String) throws -> CredentialVaultSecretRecord?
    func delete(_ name: String) throws
}

/// One generic-password item per secret in the login Keychain: service `<bundle id>.credential-vault`,
/// account = the name. Only this app reads it without a prompt (the item's access list is the
/// app that made it). Accessible after first unlock, this device only.
nonisolated struct KeychainCredentialVaultSecrets: CredentialVaultSecretStoring {
    let service: String

    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    func save(_ record: CredentialVaultSecretRecord, for name: String) throws {
        let data = try record.encoded()
        let status = SecItemUpdate(base(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(name)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux Credential Vault: \(name)"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialVault.Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialVault.Failure.keychain(status)
        }
    }

    func record(for name: String) throws -> CredentialVaultSecretRecord? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVault.Failure.keychain(status) }
        return try CredentialVaultSecretRecord(data: data)
    }

    func delete(_ name: String) throws {
        let status = SecItemDelete(base(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVault.Failure.keychain(status) }
    }
}
