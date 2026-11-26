public import Foundation
import Security

/// Device-only Keychain storage for Iroh EndpointID secret material.
public actor CmxIrohKeychainIdentityStore: CmxIrohSecureIdentityStoring {
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
        service: String = "com.cmuxterm.iroh.endpoint-identity.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyService = legacyService == service ? nil : legacyService
    }

    /// Loads one identity, adopting its same-access-group legacy record when needed.
    public func read(account: String) async throws -> Data? {
        if let current = try read(service: service, account: account) {
            return current
        }
        guard let legacyService,
              let legacy = try read(service: legacyService, account: account) else {
            return nil
        }
        try writeStored(legacy, account: account)
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
            throw CmxIrohKeychainIdentityStoreError(status: status)
        }
        return data
    }

    /// Replaces one identity in the bundle-scoped Keychain service.
    public func write(_ data: Data, account: String) async throws {
        try writeStored(data, account: account)
    }

    private func writeStored(_ data: Data, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CmxIrohKeychainIdentityStoreError(status: updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CmxIrohKeychainIdentityStoreError(status: addStatus)
        }
    }

    /// Removes one identity from the current and eligible legacy services.
    public func delete(account: String) async throws {
        try delete(query: baseQuery(service: service, account: account))
        if let legacyService {
            try delete(query: baseQuery(service: legacyService, account: account))
        }
    }

    /// Removes every identity from the current and eligible legacy services.
    public func deleteAll() async throws {
        try delete(query: baseQuery(service: service))
        if let legacyService {
            try delete(query: baseQuery(service: legacyService))
        }
    }

    /// Generates one Ed25519 secret using Security.framework.
    public static func randomSecretBytes() throws -> Data {
        let count = 32
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CmxIrohIdentityRepositoryError.randomGenerationFailed(status)
        }
        return data
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

    private func delete(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxIrohKeychainIdentityStoreError(status: status)
        }
    }
}
