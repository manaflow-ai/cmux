public import Foundation
import CmuxNextCompat

/// Where this device keeps the relay secrets it opened.
public protocol RelaySecretStore: Sendable {
    func secret(relayID: String) -> RelaySecret?
    func save(_ secret: RelaySecret, relayID: String)
    func remove(relayID: String)
}

/// Opened relay secrets in the Keychain, next to the device keys (`relay-<id>`).
public struct KeychainRelaySecretStore: RelaySecretStore {
    public let keychain: DeviceKeychain

    public init(keychain: DeviceKeychain) {
        self.keychain = keychain
    }

    /// The store of the app whose identity is ``DeviceIdentity/forApp(bundleIdentifier:)``.
    public init(bundleIdentifier: String) {
        keychain = DeviceKeychain(service: bundleIdentifier + ".device-hub")
    }

    public func secret(relayID: String) -> RelaySecret? {
        guard let data = try? keychain.read("relay-\(relayID)") else { return nil }
        return try? JSONDecoder().decode(RelaySecret.self, from: data)
    }

    public func save(_ secret: RelaySecret, relayID: String) {
        guard let data = try? JSONEncoder().encode(secret) else { return }
        try? keychain.write(data, account: "relay-\(relayID)")
    }

    public func remove(relayID: String) {
        try? keychain.delete("relay-\(relayID)")
    }
}

/// Secrets in memory only (tests, previews).
public final class MemoryRelaySecretStore: RelaySecretStore {
    private let secrets = Mutex<[String: RelaySecret]>([:])

    public init() {}

    public func secret(relayID: String) -> RelaySecret? { secrets.withLock { $0[relayID] } }
    public func save(_ secret: RelaySecret, relayID: String) { secrets.withLock { $0[relayID] = secret } }
    public func remove(relayID: String) { _ = secrets.withLock { $0.removeValue(forKey: relayID) } }
}
