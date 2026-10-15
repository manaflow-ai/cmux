import Foundation
import Security

/// The production ``CloudSecretVaultStorage``: one generic-password Keychain item.
///
/// The item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never
/// synchronizable, so the vault is encrypted by the OS, readable only after the first
/// unlock, and never leaves this Mac through iCloud Keychain or a backup restore onto
/// another device. Writes update the item in place and add it only when missing.
///
/// The data protection keychain is used when the signed app has a Keychain access group;
/// ad-hoc DEV builds lack that entitlement (`errSecMissingEntitlement`) and use the
/// login keychain with the same attributes instead.
///
/// ```swift
/// let storage = KeychainCloudSecretVaultStorage(
///     service: KeychainCloudSecretVaultStorage.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
/// )
/// ```
public struct KeychainCloudSecretVaultStorage: CloudSecretVaultStorage {
    /// The release app's service.
    public static let defaultService = "com.cmuxterm.cloud-secrets"
    static let releaseBundleIdentifier = "com.cmuxterm.app"

    public let service: String
    public let account: String

    public init(service: String, account: String = "vault-v1") {
        self.service = service
        self.account = account
    }

    /// The service for a bundle: the release app uses ``defaultService``; any other
    /// bundle (DEV and tagged builds) gets its own suffix so it never reads the release vault.
    /// - Parameter bundleIdentifier: The app's bundle identifier (the caller reads `Bundle.main`).
    public static func serviceName(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty, bundleIdentifier != releaseBundleIdentifier else {
            return defaultService
        }
        return "\(defaultService).\(bundleIdentifier)"
    }

    /// Whether this process may use the data protection keychain (the signed app has a
    /// Keychain access group). That keychain never asks for a password, so a read
    /// there is always quiet; without it the vault is in the login keychain, whose
    /// item an ad-hoc signed build can only read after a password prompt. The probe
    /// asks for attributes only, never data.
    public func isDataProtectionKeychainAvailable() -> Bool {
        var query = lookupQuery(dataProtection: true)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) != errSecMissingEntitlement
    }

    public func load() throws -> Data? {
        for dataProtection in [true, false] {
            var query = lookupQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw CloudSecretVaultStorageError.keychain(errSecDecode) }
                return data
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw CloudSecretVaultStorageError.keychain(status)
            }
        }
        return nil
    }

    public func save(_ data: Data) throws {
        let status = write(data, dataProtection: true)
        if status == errSecMissingEntitlement {
            let fallback = write(data, dataProtection: false)
            guard fallback == errSecSuccess else { throw CloudSecretVaultStorageError.keychain(fallback) }
            return
        }
        guard status == errSecSuccess else { throw CloudSecretVaultStorageError.keychain(status) }
    }

    public func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(lookupQuery(dataProtection: dataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw CloudSecretVaultStorageError.keychain(status)
            }
        }
    }

    private func write(_ data: Data, dataProtection: Bool) -> OSStatus {
        let lookup = lookupQuery(dataProtection: dataProtection)
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updateAttributes(data: data) as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        return SecItemAdd(addQuery(data: data, dataProtection: dataProtection) as CFDictionary, nil)
    }

    func lookupQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    func addQuery(data: Data, dataProtection: Bool) -> [String: Any] {
        var query = lookupQuery(dataProtection: dataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "cmux Cloud Secrets"
        return query
    }
}
