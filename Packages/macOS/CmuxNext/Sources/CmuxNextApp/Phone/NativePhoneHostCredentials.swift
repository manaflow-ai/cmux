import CmuxNativeHost
import Foundation
import Security

/// This Mac's registration with the native iPhone app's Worker (host id, host secret, Worker URL
/// and name): one generic-password item under `service` (`<bundle id>.native-phone-host`),
/// accessible after first unlock on this device only. Never written to a file or a log (the
/// `cmux-native-host` CLI keeps its own registration in a 600 file).
nonisolated struct NativePhoneHostCredentials: Sendable {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    let service: String
    static let account = "host"

    static func service(bundleID: String?) -> String {
        "\(bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next").native-phone-host"
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    /// The saved registration, nil when there is none (or it no longer decodes).
    func load() throws -> HostConfig? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return try? JSONDecoder().decode(HostConfig.self, from: data)
    }

    func save(_ config: HostConfig) throws {
        let data = try JSONEncoder().encode(config)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux iPhone host"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
