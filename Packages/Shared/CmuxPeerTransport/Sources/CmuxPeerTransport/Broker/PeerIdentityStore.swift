public import Foundation
import Security

/// The three distinct outcomes of a secure-storage read.
///
/// `absent` is a definitive "no record" answer; `unavailable` means the store
/// could not answer RIGHT NOW (Keychain before first unlock, interprocess
/// contention). Callers must never treat `unavailable` as `absent`: minting a
/// replacement identity on a transient read failure would fork the endpoint
/// identity and orphan the broker registration.
public enum PeerSecureReadResult: Equatable, Sendable {
    case found(Data)
    case absent
    case unavailable(status: Int32)
}

/// Minimal secure-storage boundary used by the identity repository and the
/// offline grant cache. Tests stub this so they run headless.
public protocol PeerSecureBlobStoring: Sendable {
    /// Loads the record for an opaque account scope.
    func read(account: String) async -> PeerSecureReadResult

    /// Replaces the record for an opaque account scope.
    func write(_ data: Data, account: String) async throws

    /// Removes one opaque account scope.
    func delete(account: String) async throws

    /// Removes every record owned by this store's service.
    func deleteAll() async throws
}

/// Keychain failures surfaced without exposing stored material.
public struct PeerIdentityStoreError: Error, Equatable, Sendable {
    /// The Security framework status code.
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

/// Device-only Keychain storage for endpoint identity secret material.
///
/// The default service and the account derivation are IDENTICAL to the
/// previous transport's store, so existing installs keep their endpoint
/// identity (and therefore their EndpointID and broker binding) across the
/// engine swap. Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// non-synchronizable, in the data-protection keychain.
public actor PeerIdentityStore: PeerSecureBlobStoring {
    /// The generic-password service the previous transport used for identity.
    public static let endpointIdentityService = "com.cmuxterm.iroh.endpoint-identity.v1"

    private let service: String
    private let accessGroup: String?

    /// Creates a Keychain store isolated by service name.
    ///
    /// - Parameters:
    ///   - service: The bundle-scoped generic-password service identifier.
    ///   - accessGroup: The app's exact signed Keychain access group.
    public init(
        service: String = PeerIdentityStore.endpointIdentityService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func read(account: String) async -> PeerSecureReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .absent
        }
        guard status == errSecSuccess, let data = result as? Data else {
            return .unavailable(status: status)
        }
        return .found(data)
    }

    public func write(_ data: Data, account: String) async throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PeerIdentityStoreError(status: updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PeerIdentityStoreError(status: addStatus)
        }
    }

    public func delete(account: String) async throws {
        try delete(query: baseQuery(account: account))
    }

    public func deleteAll() async throws {
        try delete(query: baseQuery(account: nil))
    }

    /// Generates one Ed25519 secret using Security.framework.
    public static func randomSecretBytes() throws -> Data {
        let count = 32
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PeerIdentityError.randomGenerationFailed(status)
        }
        return data
    }

    private func baseQuery(account: String?) -> [String: Any] {
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
            throw PeerIdentityStoreError(status: status)
        }
    }
}
