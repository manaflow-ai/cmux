import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

/// Metadata for one user key. The secret lives in the Keychain (imported keys)
/// or the Secure Enclave (generated keys) and never leaves the device.
public struct SSHKeyRecord: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// P-256 key created in the Secure Enclave; not exportable.
        case secureEnclave
        /// OpenSSH private key text imported by the user, stored in the Keychain.
        case imported
    }

    public var id: UUID
    public var label: String
    public var kind: Kind
    public var algorithm: String
    /// OpenSSH public key line, with the label as comment.
    public var publicKeyLine: String
    /// PRD D18: Face ID on each use, off by default.
    public var requiresBiometry: Bool
    public var createdAt: Date

    public var fingerprint: String {
        SSHHostKey(openSSHString: publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")).sha256Fingerprint
    }
}

public enum SSHKeyStoreError: Error, Equatable, Sendable {
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case missingSecret
}

/// Creates, lists, loads, and deletes user keys.
///
/// Metadata is a JSON file (not secret). Secrets are Keychain generic-password
/// items scoped to this device only (`...ThisDeviceOnly`), never synced.
public actor SSHKeyStore {
    private let metadataURL: URL
    private let keychainService: String
    private var records: [SSHKeyRecord]

    public init(directory: URL, keychainService: String = "dev.cmux.ssh.keys") {
        self.metadataURL = directory.appendingPathComponent("ssh-keys.json")
        self.keychainService = keychainService
        self.records = (try? JSONDecoder().decode([SSHKeyRecord].self, from: Data(contentsOf: metadataURL))) ?? []
    }

    public func all() -> [SSHKeyRecord] { records }

    public func record(id: UUID) -> SSHKeyRecord? { records.first { $0.id == id } }

    /// Generates a Secure Enclave P-256 key.
    public func generateSecureEnclaveKey(label: String, requiresBiometry: Bool) throws -> SSHKeyRecord {
        guard SecureEnclave.isAvailable else { throw SSHKeyStoreError.secureEnclaveUnavailable }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requiresBiometry { flags.insert(.biometryCurrentSet) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw SSHKeyStoreError.keychain(errSecParam)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        let record = SSHKeyRecord(
            id: UUID(),
            label: label,
            kind: .secureEnclave,
            algorithm: "ecdsa-sha2-nistp256",
            publicKeyLine: String(openSSHPublicKey: nioKey.publicKey) + " " + Self.comment(label),
            requiresBiometry: requiresBiometry,
            createdAt: Date()
        )
        // dataRepresentation is an opaque handle only this device's enclave can use.
        try storeSecret(key.dataRepresentation, for: record.id)
        records.append(record)
        try persist()
        return record
    }

    /// Imports an OpenSSH private key (optionally passphrase-protected).
    /// The decrypted key text is stored so later connects need no passphrase.
    public func importKey(label: String, privateKeyText: String, passphrase: String? = nil) throws -> SSHKeyRecord {
        let parsed = try SSHParsedPrivateKey(openSSH: privateKeyText, passphrase: passphrase)
        let record = SSHKeyRecord(
            id: UUID(),
            label: label,
            kind: .imported,
            algorithm: parsed.algorithm,
            publicKeyLine: parsed.publicKeyLine + " " + Self.comment(label),
            requiresBiometry: false,
            createdAt: Date()
        )
        let secret = SSHImportedKeySecret(text: privateKeyText, passphrase: passphrase)
        try storeSecret(try JSONEncoder().encode(secret), for: record.id)
        records.append(record)
        try persist()
        return record
    }

    /// Loads a usable private key. Secure Enclave keys that require biometry
    /// prompt Face ID through `context`.
    public func privateKey(for id: UUID, context: LAContext? = nil) throws -> NIOSSHPrivateKey {
        guard let record = record(id: id) else { throw SSHKeyStoreError.missingSecret }
        let secret = try loadSecret(for: id)
        switch record.kind {
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret, authenticationContext: context)
            return NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .imported:
            let stored = try JSONDecoder().decode(SSHImportedKeySecret.self, from: secret)
            return try SSHParsedPrivateKey(openSSH: stored.text, passphrase: stored.passphrase).key
        }
    }

    public func rename(id: UUID, to label: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].label = label
        try persist()
    }

    public func delete(id: UUID) throws {
        let query = baseQuery(for: id)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHKeyStoreError.keychain(status) }
        records.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Private

    private static func comment(_ label: String) -> String {
        let cleaned = label.replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "cmux-ios" : "\(cleaned)@cmux-ios"
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: metadataURL, options: [.atomic, .completeFileProtection])
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private func storeSecret(_ data: Data, for id: UUID) throws {
        var query = baseQuery(for: id)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHKeyStoreError.keychain(status) }
    }

    private func loadSecret(for id: UUID) throws -> Data {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecItemNotFound ? SSHKeyStoreError.missingSecret : SSHKeyStoreError.keychain(status)
        }
        return data
    }
}

private struct SSHImportedKeySecret: Codable {
    var text: String
    var passphrase: String?
}
