import CCmuxLayoutReducerFFI
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import Security

/// A software P-256 install key in a 0600 file (development builds only).
struct FileInstallSigner: InstallSigner {
    let file: URL

    func publicKeyX963() async throws -> Data { try key().publicKey.x963Representation }

    func sign(_ message: Data) async throws -> Data { try key().signature(for: message).rawRepresentation }

    func rotate() async throws {
        guard unlink(file.path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
/// private key never leaves the enclave. No user-presence prompt.
///
/// The blob is a generic password, service ``LoginInstallKeyKeychain/service`` (`<bundle id>.install-key[.<namespace>].<API host>`)
/// and account `install-key-<16 hex>` or a later generation of it (Rust's `install_key_slots`), in the login Keychain. Every
/// call on it (list, read, add, delete) runs on a thread of Rust's within Rust's deadline (``BoundedKeychain``): a
/// Keychain that is locked, asking for its password, or stuck ends in ``KeychainTimedOut``, which names the item,
/// never a mint (and the machine list behind it) that waits for good. None of them shows UI: an item another
/// signature of this bundle id made, or a locked Keychain, is refused, never prompted for; a delete another build's
/// item refuses moves the key to the next generation.
///
/// It stays in the login Keychain: the data-protection Keychain needs the keychain-access-groups entitlement, which
/// cmux NEXT Nightly and Stable are signed without (no provisioning profile; scripts/ci/stable-next-identity.sh
/// refuses it), so there it answers `errSecMissingEntitlement`.
struct EnclaveInstallSigner: InstallSigner {
    enum Failure: Error, CustomStringConvertible {
        case secureEnclaveUnavailable, keychain(OSStatus), rulesUnanswered

        /// The status and the system's words for it (`keychain(-25244: …)`): what a failed mint names.
        var description: String {
            switch self {
            case .secureEnclaveUnavailable: "the Secure Enclave is unavailable"
            case .keychain(let status):
                "keychain(\(status)" + ((SecCopyErrorMessageString(status, nil) as String?).map { ": \($0)" } ?? "") + ")"
            case .rulesUnanswered: "cloud_identity_install_key_slots: the app's Rust rules did not answer"
            }
        }
    }

    private let signer: SlotInstallSigner<EnclaveKey>

    init(service: String, account: String, loginKeychain: LoginKeychain) {
        signer = SlotInstallSigner(account: account, keychain: LoginInstallKeyKeychain(service: service, loginKeychain: loginKeychain))
    }

    func publicKeyX963() async throws -> Data { try await signer.publicKeyX963() }
    func sign(_ message: Data) async throws -> Data { try await signer.sign(message) }
    func rotate() async throws { try await signer.rotate() }
}

/// A private key kept as a blob in an ``InstallKeyKeychain``.
protocol SlotKey {
    static func make() throws -> Self
    init(blob: Data) throws
    var blob: Data { get }
    var publicKeyX963: Data { get }
    func sign(_ message: Data) throws -> Data
}

/// An install key whose blob lives in `keychain` under `account` or a later generation of it: made and stored at
/// its first use, a fresh one at rotation. Swift only lists, reads, adds and deletes; which item is the key, where a
/// first key goes and where a rotation puts the fresh one are Rust's (`cloud_identity_install_key_slots`).
struct SlotInstallSigner<Key: SlotKey>: InstallSigner {
    let account: String
    let keychain: any InstallKeyKeychain

    func publicKeyX963() async throws -> Data { try await key().publicKeyX963 }
    func sign(_ message: Data) async throws -> Data { try await key().sign(message) }

    func rotate() async throws {
        var deletes: [Slots.Delete] = []
        for slot in try await plan().slots { deletes.append(Slots.Delete(account: slot, status: try await keychain.delete(slot))) }
        guard let replacement = try ask(Slots.Request(account: account, accounts: [], deletes: deletes)).replacement else { return }
        try await keychain.add(replacement, try Key.make().blob)
    }

    private func key() async throws -> Key {
        let slots = try await plan()
        if let current = slots.current, let blob = try await keychain.read(current) { return try Key(blob: blob) }
        let made = try Key.make()
        try await keychain.add(slots.next, made.blob)
        return made
    }

    private func plan() async throws -> Slots {
        try ask(Slots.Request(account: account, accounts: try await keychain.accounts(), deletes: []))
    }

    private func ask(_ request: Slots.Request) throws -> Slots {
        guard let reply = CloudStartCore().call("cloud_identity_install_key_slots", request, as: Slots.self) else {
            throw EnclaveInstallSigner.Failure.rulesUnanswered
        }
        return reply
    }

    /// Rust's answer: every generation present (oldest first), the one to read, where a first key goes, and where a
    /// rotation's fresh key goes (nil: every generation went).
    struct Slots: Decodable {
        struct Request: Encodable { var account: String, accounts: [String], deletes: [Delete] }
        struct Delete: Encodable { var account: String, status: OSStatus }
        var slots: [String]
        var current: String?
        var next: String
        var replacement: String?
    }
}

/// The Keychain calls an install key's blob needs, on one Keychain service. ``delete(_:)`` answers the status instead
/// of throwing: Rust reads a refused delete (another build's item) and moves the key above it.
protocol InstallKeyKeychain: Sendable {
    /// The accounts of every item of the service (attributes only, never a secret).
    func accounts() async throws -> [String]
    func read(_ account: String) async throws -> Data?
    func add(_ account: String, _ data: Data) async throws
    func delete(_ account: String) async throws -> OSStatus
}

/// The login Keychain's generic passwords of `service`, each call through ``BoundedKeychain`` and with no UI.
struct LoginInstallKeyKeychain: InstallKeyKeychain {
    let service: String
    /// The app's one guard of the Keychain UI switch.
    let loginKeychain: LoginKeychain

    func accounts() async throws -> [String] {
        let (service, loginKeychain) = (service, loginKeychain)
        let (status, accounts) = try await BoundedKeychain.run(service: service, account: "*") { () -> (OSStatus, [String]) in
            var query = Self.query(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            var out: CFTypeRef?
            let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
            let items = (out as? [[String: Any]]) ?? (out as? [String: Any]).map { [$0] } ?? []
            return (status, items.compactMap { $0[kSecAttrAccount as String] as? String })
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
        return accounts
    }

    func read(_ account: String) async throws -> Data? {
        let (service, loginKeychain) = (service, loginKeychain)
        let (status, data) = try await BoundedKeychain.run(service: service, account: account) { () -> (OSStatus, Data?) in
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            query[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
            return (status, out as? Data)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
        return data
    }

    func add(_ account: String, _ data: Data) async throws {
        let (service, loginKeychain) = (service, loginKeychain)
        let status = try await BoundedKeychain.run(service: service, account: account) {
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // No UI either: a locked or prompting Keychain refuses the add at once.
            return loginKeychain.withoutUI { SecItemAdd(query as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
    }

    func delete(_ account: String) async throws -> OSStatus {
        let (service, loginKeychain) = (service, loginKeychain)
        return try await BoundedKeychain.run(service: service, account: account) {
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            return loginKeychain.withoutUI { SecItemDelete(query as CFDictionary) }
        }
    }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}

/// A Secure Enclave P-256 key; its blob is the enclave's encrypted key.
struct EnclaveKey: SlotKey {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    static func make() throws -> EnclaveKey {
        guard SecureEnclave.isAvailable else { throw EnclaveInstallSigner.Failure.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error) else {
            throw EnclaveInstallSigner.Failure.keychain(errSecParam)
        }
        return EnclaveKey(key: try SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
    }

    init(blob: Data) throws {
        guard SecureEnclave.isAvailable else { throw EnclaveInstallSigner.Failure.secureEnclaveUnavailable }
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    }

    private init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }

    var blob: Data { key.dataRepresentation }
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// A Keychain call on one of the app's own items that Rust's deadline ended (`cmux_keychain_bounded`,
/// cmux-cloud-config `keychain`): the Keychain is locked, asking for its password, or stuck. ``refusal`` is Rust's
/// answer `{code, message, retryable, details: {keychain: {service, account, deadline_seconds}}}`; the credential
/// relay sends it as is, and the app's error text reads ``stall``.
public struct KeychainTimedOut: Error, Sendable, Equatable, CredentialRelayRefusal, CustomStringConvertible {
    public let refusal: JSONValue

    public var relayRefusal: JSONValue { refusal }
    public var stall: KeychainStall? { KeychainStall(details: refusal["details"]) }
    public var description: String { refusal["message"]?.stringValue ?? "the Keychain did not answer" }
}

/// The Keychain item a call waited on, and for how long, from a refusal's `details` (Rust's `keychain::refusal`;
/// also the details of a Cloud op the relay refused with it).
public struct KeychainStall: Sendable, Equatable {
    public let service: String
    public let account: String
    public let seconds: Int

    public init?(details: JSONValue?) {
        guard let item = details?["keychain"], let service = item["service"]?.stringValue,
              let account = item["account"]?.stringValue, let seconds = item["deadline_seconds"]?.doubleValue else { return nil }
        (self.service, self.account, self.seconds) = (service, account, Int(seconds))
    }
}

/// Runs a Keychain call through Rust (`cmux_keychain_bounded`): on a thread of Rust's, never the caller's, and
/// answered within Rust's deadline, else ``KeychainTimedOut``. The Security call cannot be cancelled, so one that
/// never returns keeps its thread (Rust starts at most one per item). Swift only makes the call; the deadline,
/// the per-item rule and the refusal's words are Rust's.
enum BoundedKeychain {
    static func run<Value: Sendable>(service: String, account: String,
                                     _ call: @escaping @Sendable () -> Value) async throws -> Value {
        let request = try JSONEncoder().encode(["service": service, "account": account])
        let result = BoundedKeychainResult<Value>()
        return try await withCheckedThrowingContinuation { continuation in
            let pending = BoundedKeychainCall(work: { result.set(call()) }, finish: { refusal in
                if let refusal {
                    continuation.resume(throwing: KeychainTimedOut(refusal: refusal))
                } else if let value = result.value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: EnclaveInstallSigner.Failure.keychain(errSecInternalComponent))
                }
            })
            let context = Unmanaged.passRetained(pending).toOpaque()
            let code = request.withUnsafeBytes { bytes in
                cmux_keychain_bounded(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, context,
                                      boundedKeychainWork, boundedKeychainDone, boundedKeychainRelease)
            }
            guard code == CMUX_LAYOUT_REDUCER_OK else {
                // No callback ran: the context is still ours.
                Unmanaged<BoundedKeychainCall>.fromOpaque(context).release()
                continuation.resume(throwing: EnclaveInstallSigner.Failure.keychain(errSecInternalComponent))
                return
            }
        }
    }
}

/// What Rust's callbacks reach through the context: `work` runs once on Rust's call thread, `finish` once on its
/// waiter thread; each touches only its own capture (the result is behind a lock).
private final class BoundedKeychainCall: Sendable {
    let work: @Sendable () -> Void
    let finish: @Sendable (_ refusal: JSONValue?) -> Void

    init(work: @escaping @Sendable () -> Void, finish: @escaping @Sendable (_ refusal: JSONValue?) -> Void) {
        self.work = work
        self.finish = finish
    }
}

private final class BoundedKeychainResult<Value: Sendable>: Sendable {
    private let state = Mutex<Value?>(nil)
    var value: Value? { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
}

private let boundedKeychainWork: CmuxKeychainWork = { context in
    guard let context else { return }
    Unmanaged<BoundedKeychainCall>.fromOpaque(context).takeUnretainedValue().work()
}

private let boundedKeychainDone: CmuxKeychainDone = { context, answered, refusal, length in
    guard let context else { return }
    let call = Unmanaged<BoundedKeychainCall>.fromOpaque(context).takeUnretainedValue()
    guard answered == 0 else { return call.finish(nil) }
    let bytes = refusal.map { Data(bytes: $0, count: length) } ?? Data()
    call.finish((try? JSONDecoder().decode(JSONValue.self, from: bytes)) ?? .object([:]))
}

private let boundedKeychainRelease: CmuxKeychainRelease = { context in
    guard let context else { return }
    Unmanaged<BoundedKeychainCall>.fromOpaque(context).release()
}
