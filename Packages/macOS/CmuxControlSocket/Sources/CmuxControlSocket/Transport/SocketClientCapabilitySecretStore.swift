public import Foundation

/// Loads or creates the persistent master secret used for socket capabilities.
///
/// The store is an immutable adapter over synchronous Keychain operations. It
/// holds no mutable shared state; callers retain the resulting bytes in an
/// immutable ``SocketClientCapabilityAuthority`` for concurrent verification.
public struct SocketClientCapabilitySecretStore: Sendable {
    private let loadSecret: @Sendable () -> Data?
    private let saveSecret: @Sendable (Data) -> Bool
    private let randomData: @Sendable (Int) -> Data

    /// Creates a Keychain-backed secret store.
    ///
    /// - Parameters:
    ///   - service: Bundle-scoped Keychain service identifier.
    ///   - account: Keychain account; stable by default.
    public init(
        service: String,
        account: String = "socket-client-capability-master"
    ) {
        let keychain = SocketClientCapabilityKeychain(service: service, account: account)
        loadSecret = { keychain.readSecret() }
        saveSecret = { keychain.writeSecret($0) }
        randomData = { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
        }
    }

    init(
        loadSecret: @escaping @Sendable () -> Data?,
        saveSecret: @escaping @Sendable (Data) -> Bool,
        randomData: @escaping @Sendable (Int) -> Data
    ) {
        self.loadSecret = loadSecret
        self.saveSecret = saveSecret
        self.randomData = randomData
    }

    /// Returns the existing master secret or creates and persists a new one.
    ///
    /// If Keychain access is unavailable, the newly generated secret is still
    /// returned so capabilities remain stable for this app process and every
    /// listener rebind during its lifetime.
    ///
    /// - Returns: A 32-byte cryptographically random master secret.
    public func loadOrCreateSecret() -> Data {
        if let existing = loadSecret(),
           existing.count == SocketClientCapabilityAuthority.secureByteCount {
            return existing
        }
        let generated = makeEphemeralSecret()
        _ = saveSecret(generated)
        return generated
    }

    /// Creates a process-lifetime master secret without touching the Keychain.
    ///
    /// Tagged and staging builds use this to avoid prompts caused by changing
    /// development code signatures.
    ///
    /// - Returns: A 32-byte cryptographically random master secret.
    public func makeEphemeralSecret() -> Data {
        randomData(SocketClientCapabilityAuthority.secureByteCount)
    }
}
