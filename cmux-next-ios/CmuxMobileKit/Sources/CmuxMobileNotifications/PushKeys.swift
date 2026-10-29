import CryptoKit
import Foundation
import Security

/// Where the push key and the trust record live: a keychain access group the
/// app shares with its notification service extension
/// (`$(AppIdentifierPrefix)<app bundle id>.push`, Info.plist
/// `CmuxMobileKeychainGroup`), readable after the first unlock, this device
/// only. Tests use memory.
public protocol PushSecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String)
}

/// The shared keychain group.
public struct PushKeychainStore: PushSecretStore {
    public struct Failure: Error, Equatable { public let status: OSStatus }

    public let group: String
    public let service: String

    public init(group: String, service: String = "dev.cmux.mobile.push") {
        self.group = group
        self.service = service
    }

    /// The group this build is signed with; nil when Info.plist names none.
    public static func current(bundle: Bundle = .main) -> PushKeychainStore? {
        guard let group = bundle.object(forInfoDictionaryKey: "CmuxMobileKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix("$(") else { return nil }
        return PushKeychainStore(group: group)
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return out as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query(account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Memory (tests).
public final class PushMemoryStore: PushSecretStore, @unchecked Sendable { // crash-allow: lock-guarded
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}

/// What the service extension needs to open a sealed push: whose phone this
/// is, and the keys of each Mac it paired with (public keys only; each box key
/// was signed by that Mac's pinned identity key).
public struct PushTrust: Codable, Sendable, Equatable {
    public struct Mac: Codable, Sendable, Equatable {
        /// The Mac's identity key (X9.63 hex), pinned at its first pairing.
        public var identityKey: String
        /// The Mac's box key (X9.63 hex), proven by the identity key; nil from an older Mac.
        public var boxKey: String?
        /// The identity key's signature over the box key (`cmux-mobile-mac-box-v1`),
        /// checked again before each reply is sealed to it (PR B review L4).
        public var boxSignature: String?

        public init(identityKey: String, boxKey: String? = nil, boxSignature: String? = nil) {
            self.identityKey = identityKey
            self.boxKey = boxKey
            self.boxSignature = boxSignature
        }

        /// This Mac seals its pushes to this phone (it proved a box key after
        /// this phone gave it a push key): an unsealed push claiming to be from
        /// it is not acted on (PR B security review H1).
        public var sealsPushes: Bool { boxKey != nil }
    }

    /// The account the push key belongs to.
    public var user: String
    /// This phone's link device id for that account.
    public var phone: String
    public var macs: [String: Mac]

    public init(user: String, phone: String, macs: [String: Mac] = [:]) {
        self.user = user
        self.phone = phone
        self.macs = macs
    }
}

/// The phone's push key (P-256 key agreement): a Secure Enclave key on a
/// device, a software key on the simulator and in tests (as `PhoneKeys`).
/// One per account; sealed pushes are opened with it, by the app or the
/// notification service extension.
public final class PushKeys: @unchecked Sendable { // crash-allow: immutable after init
    public enum Failure: Error, Equatable {
        case unavailable
        case noKey
    }

    public let store: any PushSecretStore
    private let enclave: Bool
    /// Key creation and the trust record's read-modify-write, one at a time
    /// (the app and the service extension each hold one `PushKeys`; PR B review 6).
    private let lock = NSRecursiveLock()

    static let trustAccount = "trust"

    public init(store: any PushSecretStore, enclave: Bool = PushKeys.hasEnclave) {
        self.store = store
        self.enclave = enclave
    }

    /// This build's shared keychain; nil when it is signed without one.
    public static func current(bundle: Bundle = .main) -> PushKeys? {
        PushKeychainStore.current(bundle: bundle).map { PushKeys(store: $0) }
    }

    public static var hasEnclave: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    private static func account(_ user: String) -> String { "push-key.\(user)" }

    /// The push key's public half (X9.63), made the first time.
    public func publicKey(user: String) throws -> Data {
        try lock.withLock { try key(user: user, create: true).publicKey }
    }

    /// Opens a box sealed to this account's push key.
    public func open(_ sealed: String, user: String, context: Data) throws -> Data {
        let stored: Key = try lock.withLock { try self.key(user: user, create: false) }
        return try PushSeal.open(sealed, recipient: stored.publicKey, context: context) { try stored.agree($0) }
    }

    /// Account deletion and "Remove This iPhone": the key and the trust go.
    public func reset(user: String) {
        lock.withLock {
            store.delete(Self.account(user))
            if trust()?.user == user { store.delete(Self.trustAccount) }
        }
    }

    // MARK: Trust

    public func trust() -> PushTrust? {
        guard let data = try? store.read(Self.trustAccount) else { return nil }
        return try? JSONDecoder().decode(PushTrust.self, from: data)
    }

    /// Records `mac`'s keys for `user`'s phone `phone` (a pairing passed). A
    /// record of another account is replaced.
    public func trust(mac: String, identityKey: String, boxKey: String?, boxSignature: String? = nil, user: String, phone: String) {
        lock.withLock {
            var record = trust().flatMap { $0.user == user && $0.phone == phone ? $0 : nil } ?? PushTrust(user: user, phone: phone)
            record.macs[mac.lowercased()] = PushTrust.Mac(identityKey: identityKey.lowercased(), boxKey: boxKey?.lowercased(),
                                                          boxSignature: boxKey == nil ? nil : boxSignature?.lowercased())
            save(record)
        }
    }

    /// The person removed `mac`: its sealed pushes no longer open.
    public func forget(mac: String) {
        lock.withLock {
            guard var record = trust() else { return }
            record.macs[mac.lowercased()] = nil
            save(record)
        }
    }

    private func save(_ record: PushTrust) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? store.write(data, account: Self.trustAccount)
    }

    // MARK: Storage

    private enum Key {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)

        var publicKey: Data {
            switch self {
            case .enclave(let k): k.publicKey.x963Representation
            case .software(let k): k.publicKey.x963Representation
            }
        }

        func agree(_ peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            switch self {
            case .enclave(let k): try k.sharedSecretFromKeyAgreement(with: peer)
            case .software(let k): try k.sharedSecretFromKeyAgreement(with: peer)
            }
        }
    }

    private func key(user: String, create: Bool) throws -> Key {
        let account = Self.account(user)
        let stored = try store.read(account)
        if enclave {
            if let stored, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored) { return .enclave(key) }
            guard create else { throw Failure.noKey }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw Failure.unavailable
            }
            let made = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            try store.write(made.dataRepresentation, account: account)
            return .enclave(made)
        }
        #if DEBUG || targetEnvironment(simulator)
        if let stored, let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored) { return .software(key) }
        guard create else { throw Failure.noKey }
        let made = P256.KeyAgreement.PrivateKey()
        try store.write(made.rawRepresentation, account: account)
        return .software(made)
        #else
        throw Failure.unavailable
        #endif
    }
}
