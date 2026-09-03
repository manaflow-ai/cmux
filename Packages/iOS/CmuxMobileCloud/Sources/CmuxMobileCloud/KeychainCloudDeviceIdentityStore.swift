public import Foundation
import Security

/// Keychain-backed identity store: one generic-password item per app bundle,
/// `AfterFirstUnlockThisDeviceOnly`, so the private key never leaves this
/// device or lands in a backup.
public final class KeychainCloudDeviceIdentityStore: CloudDeviceIdentityStoring, Sendable {
    private struct Payload: Codable {
        var fingerprint: String
        var privateKey: String
    }

    private let service: String
    private let account = "cloud-device-identity"
    private let accessGroup: String?

    /// Creates a store.
    /// - Parameters:
    ///   - service: A per-bundle Keychain service name so tagged builds never
    ///     share an identity.
    ///   - accessGroup: The app's signed Keychain access group, or nil.
    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func read() -> CloudDeviceIdentityReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let keyPair = WireGuardKeyPair(privateKey: payload.privateKey),
                  !payload.fingerprint.isEmpty else {
                // A corrupt item is treated as absent so the next write repairs it.
                return .absent
            }
            return .found(CloudDeviceIdentity(fingerprint: payload.fingerprint, keyPair: keyPair))
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable
        }
    }

    public func write(_ identity: CloudDeviceIdentity) throws {
        let data = try JSONEncoder().encode(Payload(
            fingerprint: identity.fingerprint,
            privateKey: identity.keyPair.privateKey
        ))
        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CloudDeviceIdentityStoreError.keychain(updateStatus)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudDeviceIdentityStoreError.keychain(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
