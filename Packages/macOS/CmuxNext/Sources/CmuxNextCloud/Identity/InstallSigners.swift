public import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import Security

/// A software P-256 install key in a 0600 file (development builds only).
struct FileInstallSigner: InstallSigner {
    let file: URL

    func publicKeyX963() async throws -> Data { try key().publicKey.x963Representation }

    func sign(_ message: Data) async throws -> Data { try key().signature(for: message).rawRepresentation }

    func rotate() async throws { try? FileManager.default.removeItem(at: file) }

    private func key() throws -> P256.Signing.PrivateKey {
        if let raw = try? Data(contentsOf: file), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let made = P256.Signing.PrivateKey()
        try OwnerOnlyFile.write(made.rawRepresentation, to: file)
        return made
    }
}

/// The install key in the Secure Enclave (signed builds). Only the enclave's
/// encrypted key blob is stored, in the Keychain for this device only; the
/// private key never leaves the enclave. No user-presence prompt.
struct EnclaveInstallSigner: InstallSigner {
    enum Failure: Error { case secureEnclaveUnavailable, keychain(OSStatus) }

    let service: String

    func publicKeyX963() async throws -> Data { try key().publicKey.x963Representation }

    func sign(_ message: Data) async throws -> Data { try key().signature(for: message).rawRepresentation }

    func rotate() async throws { _ = SecItemDelete(query() as CFDictionary) }

    private func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        if let blob = try read() { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error) else {
            throw Failure.keychain(errSecParam)
        }
        let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try write(made.dataRepresentation)
        return made
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "install-key"]
    }

    private func read() throws -> Data? {
        var query = query()
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return out as? Data
    }

    private func write(_ data: Data) throws {
        var query = query()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
