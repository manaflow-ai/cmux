import Foundation
import CryptoKit

/// Keeps v2 endpoint seeds in a dedicated keychain service scoped to the entire identity.
public actor V2IdentityKeyStore {
    private let service: String
    private let keychain: V2KeychainStore

    /// Creates a separate v2 keychain namespace without inspecting pre-v2 or Stack entries.
    /// - Parameters:
    ///   - applicationNamespace: The app bundle's explicit namespace.
    ///   - accessGroup: An optional signing-entitled keychain group for this app.
    ///   - keychain: An injected store for behavior tests; production callers use the system store.
    public init(
        applicationNamespace: String,
        accessGroup: String? = nil,
        keychain: V2KeychainStore? = nil
    ) {
        service = applicationNamespace + ".cmux-iroh-v2.endpoint-keys"
        self.keychain = keychain ?? V2KeychainStore(
            service: service,
            accessGroup: accessGroup
        )
    }

    /// Loads or creates one key for an exact identity tuple.
    /// - Parameter identity: Environment, project, team, user, device, app namespace, and build tag.
    /// - Returns: The scope's stable v2 endpoint key.
    /// - Throws: A keychain or decoding error; never falls back to another scope.
    public func loadOrCreate(identity: V2Identity) throws -> V2IdentityKey {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
        let account = digest.map { String(format: "%02x", $0) }.joined()
        let key = V2IdentityKey()
        let data = try keychain.loadOrCreate(
            account: account,
            candidate: key.secretKey
        ) { data in
            do {
                _ = try V2IdentityKey(secretKey: data)
            } catch {
                throw V2ControlFailure.persistenceFailed
            }
        }
        do {
            return try V2IdentityKey(secretKey: data)
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }
}
