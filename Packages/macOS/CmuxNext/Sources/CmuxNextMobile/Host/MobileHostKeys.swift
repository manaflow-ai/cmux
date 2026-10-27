import CmuxIrxTransport
import CmuxNextCompat
import CmuxNextWakeups
import CryptoKit
import Foundation

/// The Mac's v2 installation id and per-identity endpoint key. The key files
/// are read and written on `work`'s files lane and the Keychain id and keys
/// on its system lane, never on a cooperative pool thread.
struct MobileHostKeys: Sendable {
    let configuration: MobileHostConfiguration
    let work: BackgroundWork

    func deviceID() async throws -> String {
        switch configuration.keyStorage {
        case .keychain:
            let namespace = configuration.namespace
            return try await work.run(.userVisible, mayBlock: .system) { try V2InstallationIDStore(applicationNamespace: namespace).loadOrCreate() }
        case .files:
            return try await work.run(.userVisible, mayBlock: .files) { try fileDeviceID() }
        }
    }

    func key(identity: V2Identity) async throws -> V2IdentityKey {
        switch configuration.keyStorage {
        case .keychain:
            let store = V2IdentityKeyStore(applicationNamespace: configuration.namespace)
            return try await work.run(.userVisible, mayBlock: .system) { try store.loadOrCreateBlocking(identity: identity) }
        case .files:
            let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
                .map { String(format: "%02x", $0) }.joined()
            return try await work.run(.userVisible, mayBlock: .files) { try fileKey(digest: digest) }
        }
    }

    /// The installation id in its file, made on first use. Blocks on the disk: runs on the files lane.
    private func fileDeviceID() throws -> String {
        let file = try directory().appendingPathComponent("installation-id")
        if let value = try? String(blockingContentsOf: file, encoding: .utf8) {
            guard UUID(uuidString: value) != nil else { throw V2ControlFailure.persistenceFailed }
            return value
        }
        let value = UUID().uuidString.lowercased()
        try write(Data(value.utf8), to: file)
        return value
    }

    /// The key of the identity whose wire digest is `digest`, made on first use. Blocks on the disk: runs on
    /// the files lane.
    private func fileKey(digest: String) throws -> V2IdentityKey {
        let file = try directory().appendingPathComponent(digest + ".key")
        if let data = try? Data(blockingContentsOf: file) { return try V2IdentityKey(secretKey: data) }
        let key = V2IdentityKey()
        try write(key.secretKey, to: file)
        return key
    }

    /// Same layout as the old app's DEBUG keys, so one bundle id keeps one identity.
    private func directory() throws -> URL {
        let directory = configuration.stateDirectory
            .appendingPathComponent("cmux-iroh-v2/development-keys", isDirectory: true)
        try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func write(_ data: Data, to file: URL) throws {
        try data.blockingWrite(to: file, options: .atomic)
        try FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
