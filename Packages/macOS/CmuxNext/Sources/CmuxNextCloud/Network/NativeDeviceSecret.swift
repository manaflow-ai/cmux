import CryptoKit
import Foundation
import Security

/// Secret storage is separate from the public device checkpoint. Tests inject a memory store.
protocol NativeDeviceSecret: Sendable {
    func load(namespace: String, create: Bool) throws -> Data
}

struct KeychainNativeDeviceSecret: NativeDeviceSecret {
    private let service: String
    init(root: URL) {
        let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        service = "com.cmuxterm.app.next.native-mesh.\(digest)"
    }
    func load(namespace: String, create: Bool) throws -> Data {
        let account = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        func existing() throws -> Data? {
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw NativeDeviceEnrollmentError.secureStorage(status) }
            guard let data = value as? Data, data.count == 32 else { throw NativeDeviceEnrollmentError.invalidState }
            return data
        }
        if let key = try existing() { return key }
        guard create else { throw NativeDeviceEnrollmentError.invalidState }
        let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        var add = query
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let winner = try existing() { return winner }
        guard status == errSecSuccess else { throw NativeDeviceEnrollmentError.secureStorage(status) }
        return key
    }
}
