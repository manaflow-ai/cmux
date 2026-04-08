import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed credential storage for VNC connections.
///
/// Service: `com.cmux.vnc`
/// Account key: `host:port` (e.g. `192.168.1.10:5900`)
/// Stored data: password (UTF-8 encoded)
///
/// Username and connection metadata are stored separately via `VNCRecentConnections`
/// in UserDefaults, since they are not secrets.
enum VNCKeychainStore {
    private static let service = "com.cmux.vnc"

    // MARK: - Save

    /// Save a VNC password to the Keychain for the given host and port.
    static func savePassword(_ password: String, host: String, port: UInt16) -> Bool {
#if canImport(Security)
        guard !password.isEmpty else {
            // Empty password — remove any existing entry
            return deletePassword(host: host, port: port)
        }

        let account = keychainAccount(host: host, port: port)
        guard let data = password.data(using: .utf8) else { return false }

        // Try updating first
        let searchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let updateAttrs: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        // Item doesn't exist — add it
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
#else
        return false
#endif
    }

    // MARK: - Load

    /// Load a VNC password from the Keychain for the given host and port.
    static func loadPassword(host: String, port: UInt16) -> String? {
#if canImport(Security)
        let account = keychainAccount(host: host, port: port)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    // MARK: - Delete

    /// Delete a VNC password from the Keychain for the given host and port.
    @discardableResult
    static func deletePassword(host: String, port: UInt16) -> Bool {
#if canImport(Security)
        let account = keychainAccount(host: host, port: port)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
#else
        return false
#endif
    }

    // MARK: - Private

    private static func keychainAccount(host: String, port: UInt16) -> String {
        "\(host):\(String(port))"
    }
}

// MARK: - Recent Connections (UserDefaults)

/// A saved VNC connection entry (non-secret fields only).
struct VNCRecentConnection: Codable, Equatable, Identifiable {
    var hostname: String
    var port: UInt16
    var username: String
    /// User-assigned name for the connection profile (optional).
    var profileName: String?

    var id: String { "\(hostname):\(String(port))" }

    var displayLabel: String {
        if let name = profileName, !name.isEmpty {
            return "\(name) (\(hostname):\(String(port)))"
        }
        if username.isEmpty {
            return "\(hostname):\(String(port))"
        }
        return "\(username)@\(hostname):\(String(port))"
    }
}

/// Stores and retrieves recent VNC connections from UserDefaults.
enum VNCRecentConnections {
    private static let key = "VNCRecentConnections"
    private static let maxRecent = 20

    /// All saved recent connections, most-recently-used first.
    static func load() -> [VNCRecentConnection] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([VNCRecentConnection].self, from: data)) ?? []
    }

    /// Save or update a connection at the front of the recents list.
    /// If a connection with the same host:port already exists, it is moved to the front
    /// and its username/profileName are updated.
    static func upsert(_ connection: VNCRecentConnection) {
        var list = load()
        list.removeAll { $0.hostname == connection.hostname && $0.port == connection.port }
        list.insert(connection, at: 0)
        if list.count > maxRecent {
            list = Array(list.prefix(maxRecent))
        }
        save(list)
    }

    /// Remove a connection from the recents list.
    static func remove(host: String, port: UInt16) {
        var list = load()
        list.removeAll { $0.hostname == host && $0.port == port }
        save(list)
    }

    private static func save(_ list: [VNCRecentConnection]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
