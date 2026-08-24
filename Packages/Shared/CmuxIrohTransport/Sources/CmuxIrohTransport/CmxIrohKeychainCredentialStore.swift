public import Foundation
import Security

/// Device-only Keychain storage for Iroh relay capabilities.
public actor CmxIrohKeychainCredentialStore: CmxIrohSecureCredentialStoring {
    private let service: String
    private let accessGroup: String?
    private let legacyService: String?

    /// Creates a Keychain store isolated by service name.
    ///
    /// - Parameters:
    ///   - service: The bundle-scoped generic-password service identifier.
    ///   - accessGroup: The app's exact signed Keychain access group.
    ///   - legacyService: An older service whose item may be adopted only from
    ///     the same exact access group.
    public init(
        service: String = "com.cmuxterm.iroh.relay-credentials.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyService = legacyService == service ? nil : legacyService
    }

    /// Loads one opaque-scope capability from Keychain.
    ///
    /// - Parameter account: The repository-derived scope.
    /// - Returns: The stored capability, or `nil` when none exists.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func read(account: String) throws -> Data? {
        if let current = try read(service: service, account: account) {
            return current
        }
        guard let legacyService,
              let legacy = try read(service: legacyService, account: account) else {
            return nil
        }
        try write(
            legacy,
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        try delete(query: baseQuery(service: legacyService, account: account))
        return legacy
    }

    private func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CmxIrohKeychainCredentialStoreError(status: status)
        }
        return data
    }

    /// Upserts one opaque-scope capability with the requested data protection.
    ///
    /// - Parameters:
    ///   - data: The encoded capability.
    ///   - account: The repository-derived scope.
    ///   - accessibility: The required data-protection policy.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: secAccessibility(accessibility),
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CmxIrohKeychainCredentialStoreError(status: updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw CmxIrohKeychainCredentialStoreError(status: addStatus)
        }
        let retryStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard retryStatus == errSecSuccess else {
            throw CmxIrohKeychainCredentialStoreError(status: retryStatus)
        }
    }

    /// Removes one opaque-scope capability from Keychain.
    ///
    /// - Parameter account: The repository-derived scope.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func delete(account: String) throws {
        try delete(query: baseQuery(service: service, account: account))
        if let legacyService {
            try delete(query: baseQuery(service: legacyService, account: account))
        }
    }

    /// Removes every relay capability owned by this Keychain service.
    ///
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func deleteAll() throws {
        try delete(query: baseQuery(service: service))
        if let legacyService {
            try delete(query: baseQuery(service: legacyService))
        }
    }

    private func baseQuery(
        service: String,
        account: String? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func secAccessibility(
        _ accessibility: CmxIrohSecureCredentialAccessibility
    ) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private func delete(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxIrohKeychainCredentialStoreError(status: status)
        }
    }
}
