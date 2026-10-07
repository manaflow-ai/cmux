public import Foundation
import Security

/// Where the Mac's install key handle lives, the same split the irx host
/// uses for its v2 keys (`MobileHostConfiguration.KeyStorage`): a 0600 file in
/// the app's state directory for DEV builds (no Keychain prompt per tag), the
/// login Keychain (`ThisDeviceOnly`) for release builds. A Secure Enclave
/// handle is useless off this Mac; a software key is the fallback where the
/// enclave refuses (no enclave, an unsigned build).
public enum MacInstallKeyStorage: Sendable, Hashable {
    case file(URL)
    case keychain(service: String)

    public enum Failure: Error, Hashable { case keychain(OSStatus), file }

    func read() throws -> Data? {
        switch self {
        case .file(let url):
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return data
        case .keychain(let service):
            var query = Self.query(service)
            query[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            return out as? Data
        }
    }

    func write(_ data: Data) throws {
        switch self {
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.file
            }
        case .keychain(let service):
            SecItemDelete(Self.query(service) as CFDictionary)
            var query = Self.query(service)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }
    }

    func delete() {
        switch self {
        case .file(let url): try? FileManager.default.removeItem(at: url)
        case .keychain(let service): SecItemDelete(Self.query(service) as CFDictionary)
        }
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "install-key", kSecAttrSynchronizable as String: false]
    }
}
