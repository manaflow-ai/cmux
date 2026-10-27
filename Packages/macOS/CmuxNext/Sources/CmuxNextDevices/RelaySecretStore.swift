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

/// The relay secret store's calls, one at a time and never on the main actor:
/// the app's store is the Keychain, whose reads took 8-20 s on the main
/// thread in the H7 walkthrough. Opening a sealed secret uses the Secure
/// Enclave key, so it runs here too.
actor RelaySecretVault {
    let store: any RelaySecretStore

    init(store: any RelaySecretStore) {
        self.store = store
    }

    /// After a relays listing: drops the secrets of relays no longer listed (except
    /// `keeping`, just saved here), opens and keeps the secrets sealed to this
    /// device, and returns every secret this device holds for the listed and kept relays.
    func sync(listed: [HubRelay], keeping: Set<String>, identity: DeviceIdentity) -> [String: RelaySecret] {
        let ids = Set(listed.map(\.id))
        for id in store.relayIDs() where !ids.contains(id) && !keeping.contains(id) {
            store.remove(relayID: id)
        }
        let sealing = RelaySealing(identity: identity)
        var opened: [String: RelaySecret] = [:]
        for relay in listed {
            let held = store.secret(relayID: relay.id)
            if let blob = relay.sealedForThisDevice, let secret = try? sealing.open(blob, relayID: relay.id) {
                if held != secret { store.save(secret, relayID: relay.id) }
                opened[relay.id] = secret
            } else if let held {
                opened[relay.id] = held
            }
        }
        for id in keeping where opened[id] == nil {
            if let held = store.secret(relayID: id) { opened[id] = held }
        }
        return opened
    }

    func save(_ secret: RelaySecret, relayID: String) {
        store.save(secret, relayID: relayID)
    }

    func remove(relayID: String) {
        store.remove(relayID: relayID)
    }
}
