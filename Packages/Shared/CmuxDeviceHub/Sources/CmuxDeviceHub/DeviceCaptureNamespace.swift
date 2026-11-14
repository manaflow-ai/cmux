public import Foundation
import Security

/// Strict, non-interactive cleanup of a namespace already claimed by a capture lease.
/// Callers must stop every writer and prove ownership before calling `remove()`.
public struct DeviceCaptureNamespace: Sendable {
    public struct Removal: Sendable, Equatable {
        public let identities: Int
        public let relays: Int
        public init(identities: Int, relays: Int) { self.identities = identities; self.relays = relays }
    }

    private let accounts: @Sendable (Bool) throws -> [String]
    private let delete: @Sendable (Bool, String) throws -> Bool

    public init(bundleIdentifier: String) {
        let service = bundleIdentifier + ".device-hub"
        accounts = { try Self.accounts(service: service, dataProtection: $0) }
        delete = { protected, account in
            var query = Self.query(service: service, dataProtection: protected)
            query[kSecAttrAccount as String] = account
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceIdentity.Failure.keychain(status) }
            return status == errSecSuccess
        }
    }

    init(accounts: @escaping @Sendable (Bool) throws -> [String], delete: @escaping @Sendable (Bool, String) throws -> Bool) {
        self.accounts = accounts; self.delete = delete
    }

    /// Errors, including entitlement failures, are never converted to an empty namespace.
    public func isEmpty() throws -> Bool {
        try accounts(false).isEmpty && accounts(true).isEmpty
    }

    /// Removes only known device/relay accounts, then verifies both Keychain stores.
    public func remove() throws -> Removal {
        let stores = try [false, true].map { ($0, try accounts($0)) }
        let identity = Set(["device-id", "device-signing-key", "device-agreement-key"])
        guard stores.allSatisfy({ $0.1.allSatisfy { identity.contains($0) || $0.hasPrefix("relay-") } }) else {
            throw DeviceIdentity.Failure.keychain(errSecParam)
        }
        var identities = 0, relays = 0
        for (protected, names) in stores {
            for account in names {
                if try delete(protected, account) {
                    if identity.contains(account) { identities += 1 } else { relays += 1 }
                }
            }
        }
        guard try isEmpty() else { throw DeviceIdentity.Failure.keychain(errSecDuplicateItem) }
        return Removal(identities: identities, relays: relays)
    }

    private static func query(service: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
                                   kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func accounts(service: String, dataProtection: Bool) throws -> [String] {
        var query = query(service: service, dataProtection: dataProtection)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw DeviceIdentity.Failure.keychain(status) }
        let names = items.compactMap { $0[kSecAttrAccount as String] as? String }
        guard names.count == items.count else { throw DeviceIdentity.Failure.keychain(errSecDecode) }
        return names
    }
}
