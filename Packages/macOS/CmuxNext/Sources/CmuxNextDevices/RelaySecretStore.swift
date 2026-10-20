public import Foundation
import CmuxNextCompat
import Security

/// Where this device keeps the relay secrets it opened.
public protocol RelaySecretStore: Sendable {
    func secret(relayID: String) -> RelaySecret?
    func save(_ secret: RelaySecret, relayID: String)
    func remove(relayID: String)
    /// The relays this device holds a secret for.
    func relayIDs() -> [String]
}

/// Opened relay secrets (`relay-<id>`) in the data-protection keychain under
/// the bundle's `<bundle id>.device-hub` service, like the app's other
/// secrets. A secret an earlier build kept in the file keychain moves over
/// on its first read. A build without the keychain-access-groups
/// entitlement (errSecMissingEntitlement) keeps using the file keychain.
public struct KeychainRelaySecretStore: RelaySecretStore {
    public let keychain: DeviceKeychain
    /// The file keychain earlier builds wrote to (read once, then emptied).
    let legacy: DeviceKeychain?

    public init(keychain: DeviceKeychain) {
        self.keychain = keychain
        legacy = nil
    }

    /// The store of the app whose identity is ``DeviceIdentity/forApp(bundleIdentifier:)``.
    public init(bundleIdentifier: String) {
        keychain = DeviceKeychain(service: bundleIdentifier + ".device-hub", dataProtection: true)
        legacy = DeviceKeychain(service: bundleIdentifier + ".device-hub")
    }

    public func secret(relayID: String) -> RelaySecret? {
        let account = "relay-\(relayID)"
        let data: Data?
        do { data = try keychain.read(account) } catch let failure as DeviceIdentity.Failure where Self.missingEntitlement(failure) {
            data = try? legacy?.read(account)
        } catch { data = nil }
        if let data { return try? JSONDecoder().decode(RelaySecret.self, from: data) }
        // An earlier build's file keychain item: move it over.
        guard let legacy, let old = try? legacy.read(account), let secret = try? JSONDecoder().decode(RelaySecret.self, from: old) else {
            return nil
        }
        if (try? keychain.write(old, account: account)) != nil { try? legacy.delete(account) }
        return secret
    }

    public func save(_ secret: RelaySecret, relayID: String) {
        guard let data = try? JSONEncoder().encode(secret) else { return }
        let account = "relay-\(relayID)"
        do {
            try keychain.write(data, account: account)
            try? legacy?.delete(account)
        } catch let failure as DeviceIdentity.Failure where Self.missingEntitlement(failure) {
            try? legacy?.write(data, account: account)
        } catch {}
    }

    public func remove(relayID: String) {
        try? keychain.delete("relay-\(relayID)")
        try? legacy?.delete("relay-\(relayID)")
    }

    public func relayIDs() -> [String] {
        let accounts = keychain.accounts() + (legacy?.accounts() ?? [])
        return Array(Set(accounts.filter { $0.hasPrefix("relay-") }.map { String($0.dropFirst(6)) })).sorted()
    }

    static func missingEntitlement(_ failure: DeviceIdentity.Failure) -> Bool {
        failure == .keychain(errSecMissingEntitlement)
    }
}

/// Secrets in memory only (tests, previews).
public final class MemoryRelaySecretStore: RelaySecretStore {
    private let secrets = Mutex<[String: RelaySecret]>([:])

    public init() {}

    public func secret(relayID: String) -> RelaySecret? { secrets.withLock { $0[relayID] } }
    public func save(_ secret: RelaySecret, relayID: String) { secrets.withLock { $0[relayID] = secret } }
    public func remove(relayID: String) { _ = secrets.withLock { $0.removeValue(forKey: relayID) } }
    public func relayIDs() -> [String] { secrets.withLock { $0.keys.sorted() } }
}
