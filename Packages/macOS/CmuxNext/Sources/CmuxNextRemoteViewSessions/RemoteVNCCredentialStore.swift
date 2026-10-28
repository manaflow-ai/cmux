import CmuxNextCompat
import CmuxVNC
import Foundation
import Security

#if DEBUG
/// VNC sign-ins in the login Keychain, one generic password per
/// `host:port`. Never in the tab record: records persist and travel.
nonisolated struct RemoteVNCCredentialStore {
    static let service = "cmux-next VNC"

    private struct Stored: Codable {
        var username: String?
        var password: String?
    }

    func credentials(for endpoint: VNCEndpoint) -> VNCCredentials? {
        keychainCredentials(for: endpoint) ?? debugFileCredentials()
    }

    /// Unattended live checks (scripts/cmux-next/remote-view-vnc-live.py): a
    /// JSON `{username, password}` file named by
    /// `CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE`, readable by this user only. An
    /// SSH session cannot unlock the login Keychain. Development builds only,
    /// like the rest of this file.
    func debugFileCredentials() -> VNCCredentials? {
        guard let path = ProcessInfo.processInfo.environment["CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE"],
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().blockingDecode(Stored.self, from: data) else { return nil }
        return VNCCredentials(username: stored.username, password: stored.password)
    }

    func keychainCredentials(for endpoint: VNCEndpoint) -> VNCCredentials? {
        var query = baseQuery(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard blockingSecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().blockingDecode(Stored.self, from: data) else { return nil }
        return VNCCredentials(username: stored.username, password: stored.password)
    }

    func save(_ credentials: VNCCredentials, for endpoint: VNCEndpoint) {
        guard let data = try? JSONEncoder().encode(Stored(username: credentials.username, password: credentials.password)) else { return }
        let query = baseQuery(endpoint)
        let update = [kSecValueData as String: data]
        if blockingSecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            _ = blockingSecItemAdd(add as CFDictionary, nil)
        }
    }

    func remove(for endpoint: VNCEndpoint) {
        _ = blockingSecItemDelete(baseQuery(endpoint) as CFDictionary)
    }

    /// The saved sign-ins' accounts (`host:port`), attributes only: reading no secret, it raises no Keychain
    /// access prompt. Nil when the list cannot be read.
    func accounts() -> Set<String>? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = blockingSecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    private func baseQuery(_ endpoint: VNCEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: endpoint.label,
        ]
    }
}
#endif
