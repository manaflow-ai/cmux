import Foundation
#if canImport(Security)
import Security
#endif

struct MobilePairedMacKeychainAttachTokenSecretStore: MobileAttachTokenSecretStoring {
    private let service: String

    init(bundleIdentifier: String?) {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            self.service = "\(bundleIdentifier).mobile-attach-token"
        } else {
            self.service = "com.cmuxterm.app.mobile-attach-token"
        }
    }

    init(service: String) {
        self.service = service
    }

    func readAttachToken(account: String) -> String? {
        keychainRead(account: account)
    }

    func saveAttachToken(_ token: String, account: String) -> Bool {
        keychainWrite(token, account: account)
    }

    func deleteAttachToken(account: String) {
        keychainDelete(account: account)
    }

#if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func keychainRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                pairedMacStoreLog.warning(
                    "attach token keychain read failed status=\(status, privacy: .public) account=\(account, privacy: .private)"
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        keychainDelete(account: account)
        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            pairedMacStoreLog.warning(
                "attach token keychain write failed status=\(status, privacy: .public) account=\(account, privacy: .private)"
            )
            return false
        }
        return true
    }

    private func keychainDelete(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
#else
    private func keychainRead(account: String) -> String? { nil }
    private func keychainWrite(_ value: String, account: String) -> Bool { false }
    private func keychainDelete(account: String) {}
#endif
}
