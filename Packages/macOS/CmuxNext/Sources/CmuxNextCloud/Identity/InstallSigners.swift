public import CmuxInstallAuthCore
import CmuxNextCompat
import CmuxNextWakeups
import CryptoKit
public import Foundation
import Security

/// A software P-256 install key in a 0600 file (development builds only).
/// Every key read, write and unlink runs on `work`'s files lane, never on the
/// caller's thread (a token mint awaits it from the main actor).
struct FileInstallSigner: InstallSigner {
    let file: URL
    let work: BackgroundWork

    func publicKeyX963() async throws -> Data {
        try await work.run(.userVisible, mayBlock: .files) { [self] in try key().publicKey.x963Representation }
    }

    func sign(_ message: Data) async throws -> Data {
        try await work.run(.userVisible, mayBlock: .files) { [self] in try key().signature(for: message).rawRepresentation }
    }

    func rotate() async throws {
        try await work.run(.userVisible, mayBlock: .files) { [file] in
            guard blockingUnlink(file.path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func key() throws -> P256.Signing.PrivateKey {
        if let raw = try? Data(contentsOf: file), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let made = P256.Signing.PrivateKey()
        try OwnerOnlyFile.write(made.rawRepresentation, to: file)
        return made
    }
}

/// The install key in the Secure Enclave (signed builds). Only the enclave's
/// encrypted key blob is stored, in the Keychain for this device only; the
/// private key never leaves the enclave. No user-presence prompt. Every
/// Keychain and enclave call waits on securityd, so it runs on `work`'s
/// system lane, never on the caller's thread.
struct EnclaveInstallSigner: InstallSigner {
    enum Failure: Error { case secureEnclaveUnavailable, keychain(OSStatus) }

    let service: String
    let account: String
    let work: BackgroundWork

    func publicKeyX963() async throws -> Data {
        try await work.run(.userVisible, mayBlock: .system) { [self] in try key().publicKey.x963Representation }
    }

    func sign(_ message: Data) async throws -> Data {
        try await work.run(.userVisible, mayBlock: .system) { [self] in try key().signature(for: message).rawRepresentation }
    }

    func rotate() async throws {
        try await work.run(.userVisible, mayBlock: .system) { [self] in
            let status = blockingSecItemDelete(query() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        }
    }

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
         kSecAttrAccount as String: account]
    }

    private func read() throws -> Data? {
        var query = query()
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = blockingSecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return out as? Data
    }

    private func write(_ data: Data) throws {
        var query = query()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = blockingSecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
