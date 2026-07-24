import Foundation
import Security

/// Persistence for the phone's stable device-registry id.
///
/// The id must survive an app reinstall so the iroh binding slot keyed on
/// `(user, device, tag)` is reused instead of orphaned. iOS `UserDefaults` is
/// erased on delete/reinstall, but a device-only Keychain item is not, so the
/// Keychain is authoritative and `UserDefaults` is only a legacy migration
/// source and downgrade mirror.
protocol DeviceIdentityStoring: Sendable {
    func read() -> String?
    func write(_ deviceID: String)
}

/// Device-only Keychain storage for the device-registry id.
///
/// Uses a service name distinct from the iroh endpoint-identity store, so the
/// reinstall/sign-out wipe in `CmxIrohIdentityRepository` (which deletes only
/// the endpoint-identity service) never removes this id. Best-effort: a failed
/// read returns `nil` and a failed write is ignored, so a context without
/// Keychain access (e.g. a plain SwiftPM test host) degrades to the
/// `UserDefaults` fallback instead of trapping.
struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.cmuxterm.deviceRegistry.iosDeviceID.v1",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func write(_ deviceID: String) {
        guard let data = deviceID.data(using: .utf8) else { return }
        let query = baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(insert as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// In-memory device-identity store for tests. Not for production use.
final class InMemoryDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(seed: String? = nil) {
        value = seed
    }

    func read() -> String? {
        lock.withLock { value }
    }

    func write(_ deviceID: String) {
        lock.withLock { value = deviceID }
    }
}
