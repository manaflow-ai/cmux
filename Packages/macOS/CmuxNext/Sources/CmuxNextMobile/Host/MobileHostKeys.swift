import CmuxIrxTransport
import CryptoKit
import Foundation

/// The Mac's v2 installation id and per-identity endpoint key.
struct MobileHostKeys: Sendable {
    let configuration: MobileHostConfiguration

    func deviceID() throws -> String {
        switch configuration.keyStorage {
        case .keychain:
            return try V2InstallationIDStore(applicationNamespace: configuration.namespace).loadOrCreate()
        case .files:
            let file = try directory().appendingPathComponent("installation-id")
            if let value = try? String(contentsOf: file, encoding: .utf8) {
                guard UUID(uuidString: value) != nil else { throw V2ControlFailure.persistenceFailed }
                return value
            }
            let value = UUID().uuidString.lowercased()
            try write(Data(value.utf8), to: file)
            return value
        }
    }

    func key(identity: V2Identity) async throws -> V2IdentityKey {
        switch configuration.keyStorage {
        case .keychain:
            return try await V2IdentityKeyStore(applicationNamespace: configuration.namespace).loadOrCreate(identity: identity)
        case .files:
            let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
                .map { String(format: "%02x", $0) }.joined()
            let file = try directory().appendingPathComponent(digest + ".key")
            if let data = try? Data(contentsOf: file) { return try V2IdentityKey(secretKey: data) }
            let key = V2IdentityKey()
            try write(key.secretKey, to: file)
            return key
        }
    }

    /// Same layout as the old app's DEBUG keys, so one bundle id keeps one identity.
    private func directory() throws -> URL {
        let directory = configuration.stateDirectory
            .appendingPathComponent("cmux-iroh-v2/development-keys", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
