public import Foundation
import Security

/// The account-label salt in the Keychain: one generic-password item under
/// `<bundle id>.account-label-salt`, created on first use with 32 random
/// bytes, accessible after first unlock on this device only (it never
/// syncs, so handles are per Mac and per user).
public struct KeychainAccountLabelSalt: AccountLabelSaltProviding {
    public let service: String
    static let account = "salt"

    public init(service: String) {
        self.service = service
    }

    public static func service(bundleID: String?) -> String {
        "\(bundleID?.isEmpty == false ? bundleID ?? "" : "com.cmuxterm.app").account-label-salt"
    }

    public func salt() throws -> Data {
        if let existing = try read() { return existing }
        let fresh = AccountLabelSalt.random()
        var add = base()
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "cmux account label salt"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return fresh }
        // Another process created it first: use that one.
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        throw ProviderKeyStoreError(status: status)
    }

    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    private func read() throws -> Data? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ProviderKeyStoreError(status: status) }
        return data
    }
}
