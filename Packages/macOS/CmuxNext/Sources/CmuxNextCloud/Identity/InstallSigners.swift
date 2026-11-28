import CCmuxLayoutReducerFFI
import CmuxNextCompat
public import CmuxNextDaemon
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

// MARK: - Install auth client (drives cmux-cloud-config's install_auth; rules are Rust)

/// The install's P-256 key. The private half never leaves the signer (the
/// Secure Enclave on a device); only the public point and signatures do.
public protocol InstallSigner: Sendable {
    /// Uncompressed public point (X9.63: 0x04 || x || y, 65 bytes).
    func publicKeyX963() async throws -> Data
    /// ES256 over `message` (SHA-256 inside), raw r||s (64 bytes) or DER.
    func sign(_ message: Data) async throws -> Data
    /// Replaces the key (a revoked install, or a key the owner already holds
    /// for another install). The old private key is destroyed.
    func rotate() async throws
}

public enum InstallAuthError: Error, Hashable, Sendable {
    case invalidPublicKey
    case noSession
    case refused(String)
    /// The owner sent a challenge this client will not sign.
    case unexpectedChallenge
    /// `user.ensure` answered for a different Stack user than the session's.
    case userMismatch
    /// The request to `path` got no HTTP answer; `urlErrorCode` is the
    /// transport's `URLError` code when it threw one (-1001: timed out).
    case transport(path: String, urlErrorCode: Int?)
    case malformedReply
    /// The team requires a newer app (`updates.minimumVersion`); the owner
    /// names the minimum. Not an install problem: the key and record stay,
    /// and the same install mints again once the app is updated.
    case clientTooOld(minimumVersion: String?)

    /// The error a `fail` effect of cmux-cloud-config's install_auth names.
    init(failure effect: [String: Any]) {
        switch effect["error"] as? String {
        case "invalid_public_key": self = .invalidPublicKey
        case "no_session": self = .noSession
        case "refused": self = .refused(effect["code"] as? String ?? "unknown")
        case "unexpected_challenge": self = .unexpectedChallenge
        case "user_mismatch": self = .userMismatch
        case "transport":
            self = .transport(path: effect["path"] as? String ?? "", urlErrorCode: (effect["url_error_code"] as? NSNumber)?.intValue)
        case "client_too_old": self = .clientTooOld(minimumVersion: effect["minimum_version"] as? String)
        default: self = .malformedReply
        }
    }
}

/// What a log line or a relay answer says of a failed mint: the step and its code. Never a token.
extension InstallAuthError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPublicKey: "the install key is not a P-256 point"
        case .noSession: "no sign-in session to register the install with"
        case .refused(let code): "the cmux API refused the install token request (\(code))"
        case .unexpectedChallenge: "the cmux API sent a challenge this install will not sign"
        case .userMismatch: "the cmux API answered for another user"
        case .transport(let path, let code):
            "POST \(path) got no answer" + (code.map { " (URLError \($0))" } ?? "")
        case .malformedReply: "the cmux API answered the install token request with no token"
        case .clientTooOld(let minimum): "this cmux is too old for the team" + (minimum.map { " (needs \($0))" } ?? "")
        }
    }
}

/// The public JWK the owner stores for a key.
public struct PublicJWK: Hashable, Sendable {
    public var x: String
    public var y: String

    public init(x963: Data) throws {
        guard x963.count == 65, x963.first == 0x04 else { throw InstallAuthError.invalidPublicKey }
        x = (x963.subdata(in: 1..<33)).base64URLEncoded
        y = (x963.subdata(in: 33..<65)).base64URLEncoded
    }

    public var json: [String: String] { ["kty": "EC", "crv": "P-256", "x": x, "y": y] }
}

extension Data {
    /// base64url without padding (RFC 4648 section 5).
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One HTTP exchange; the app supplies a redirect-refusing session.
public protocol InstallAuthTransport: Sendable {
    /// POSTs JSON to `path` (relative to the API Worker) with an optional
    /// bearer and extra request `headers` (for example the client version).
    /// Returns the status and body.
    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data)
    /// GETs `path` (relative to the API Worker, query included) with an optional bearer and extra `headers`.
    func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data)
}

extension InstallAuthTransport {
    /// A transport that only posts (the install-auth exchange needs no GET) answers a GET as unsupported.
    public func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        throw URLError(.unsupportedURL)
    }
}

/// What the install keeps between launches (never the token).
public struct InstallRecord: Codable, Hashable, Sendable {
    public var user: String
    public var install: String

    public init(user: String, install: String) {
        self.user = user
        self.install = install
    }
}

/// What an install registers as: its kind, display name, platform and the
/// op classes it asks for (the backend's default for the kind, which a
/// register may narrow but never widen; user.ts defaultInstallClasses).
public struct InstallProfile: Hashable, Sendable {
    public var kind: String
    public var name: String
    public var platform: String
    public var opClasses: [String]
    /// The device name when the system gives none.
    public var fallbackDeviceName: String

    public init(kind: String, name: String, platform: String, opClasses: [String], fallbackDeviceName: String) {
        self.kind = kind
        self.name = name
        self.platform = platform
        self.opClasses = opClasses
        self.fallbackDeviceName = fallbackDeviceName
    }

    /// The cmux Mac app (cx-wb5.64): the phone grant plus `mutate-shared`
    /// (start, pause and rename team machines through the credential relay);
    /// never `execute`. The server caps a mac register to this set.
    public static let mac = InstallProfile(kind: "mac", name: "cmux", platform: "macos",
                                           opClasses: ["read", "mutate-own", "mutate-shared", "cloud-link"], fallbackDeviceName: "Mac")

    var wire: [String: Any] {
        ["kind": kind, "name": name, "platform": platform, "op_classes": opClasses, "fallback_device_name": fallbackDeviceName]
    }
}

/// The install principal client for one Stack user. Registration needs the
/// user's Stack session; minting a token needs only the record and the key,
/// so a background launch or a sign-out cleanup can still act as the install.
/// Every token comes from a fresh challenge; tokens live only in memory.
///
/// Every rule of the exchange (which request comes next, what each answer must say, which
/// refusals recover, how long a token is trusted) is cmux-cloud-config's `install_auth` step
/// machine, asked over the app FFI (`cloud_identity_install_auth_step`). This actor performs
/// its effects: the HTTP exchange, the signer, the Stack session, the record, and the one
/// shared in-flight mint with its cancellation.
public actor InstallAuthClient {
    public typealias SessionToken = @Sendable () async throws -> String

    private let transport: any InstallAuthTransport
    private let signer: any InstallSigner
    private let sessionToken: SessionToken?
    private let stackUser: String
    /// One immutable requested team per client; its token cache cannot cross scopes.
    private let team: String?
    /// The API's `ENVIRONMENT`, learned from the server (the challenge prefix names it and the
    /// minted token's issuer must agree). A scoped client can pin the one its personal client learned.
    public private(set) var environment: String?
    private let deviceName: String
    private let profile: InstallProfile
    /// This app's version, sent as `x-cmux-client-version`; the owner refuses an older one when
    /// the team sets `updates.minimumVersion` (enterprise P17).
    private let clientVersion: String?
    private let onRecord: (@Sendable (InstallRecord?) async -> Void)?
    private let now: @Sendable () -> Date
    private var record: InstallRecord?
    private var token: (value: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?

    /// Refresh this long before the token expires.
    public static let refreshMargin: TimeInterval = 60
    /// The header the owner's version gate reads (token mint and wire connects).
    public static let clientVersionHeader = "x-cmux-client-version"
    /// The most effects one mint or revoke performs before the client gives up on it.
    static let maximumSteps = 64

    /// - Parameters:
    ///   - team: One backend team id, fixed for this client and its token cache. Nil keeps personal issuance.
    ///   - expectedEnvironment: The environment already verified by the enclosing account client, when available.
    ///   - onRecord: persists the record (Keychain) the moment it changes; nil keeps it in memory only.
    public init(transport: any InstallAuthTransport, signer: any InstallSigner, sessionToken: SessionToken?,
                stackUser: String, deviceName: String, clientVersion: String?, record: InstallRecord?,
                profile: InstallProfile = .mac, team: String? = nil, expectedEnvironment: String? = nil,
                onRecord: (@Sendable (InstallRecord?) async -> Void)? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.signer = signer
        self.sessionToken = sessionToken
        self.stackUser = stackUser
        self.team = team
        self.environment = expectedEnvironment
        self.deviceName = deviceName
        self.profile = profile
        self.clientVersion = clientVersion
        self.record = record
        self.onRecord = onRecord
        self.now = now
    }

    public var currentRecord: InstallRecord? { record }

    /// A valid install token, minting a new one when needed. Concurrent
    /// callers share one mint.
    public func installToken() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        if let inflight { return try await inflight.value }
        let task = Task { try await self.mint() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// A valid install token, minted in the caller's own task, so cancelling the caller cancels
    /// the mint's requests. For a client with one caller: nothing is shared with other callers.
    public func installTokenInCallerTask() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        return try await mint()
    }

    /// L14-2: sign-out revokes this install (needs the Stack session; the
    /// owner also drops the install's push targets). The key is rotated and
    /// the record forgotten, so the next sign-in registers a new install.
    public func revoke() async throws {
        let effect = try await drive(mode: "revoke")
        guard effect["revoked"] as? Bool == true else { return }
        reset()
        self.record = nil
        await onRecord?(nil)
        try await signer.rotate()
    }

    /// The owner refused the current token (401): mint a new one next time.
    public func invalidate() { token = nil }

    /// Sign-out: forget the token (the record stays for cleanup ops).
    public func reset() {
        inflight?.cancel()
        inflight = nil
        token = nil
    }

    /// The headers every request carries.
    public static func headers(clientVersion: String?) -> [String: String] {
        guard let clientVersion, !clientVersion.isEmpty else { return [:] }
        return [clientVersionHeader: clientVersion]
    }

    private func mint() async throws -> String {
        let effect = try await drive(mode: "mint")
        guard let value = effect["token"] as? String, let named = effect["environment"] as? String,
              let expiresAt = (effect["expires_at_ms"] as? NSNumber)?.doubleValue else {
            throw InstallAuthError.malformedReply
        }
        // A mint cancelled by reset() (sign-out) must not store its token.
        try Task.checkCancellation()
        environment = named
        token = (value, Date(timeIntervalSince1970: expiresAt / 1000))
        return value
    }

    /// Runs the step machine from its start to `done` or `revoked`, performing each effect.
    private func drive(mode: String) async throws -> [String: Any] {
        var state: Any = NSNull()
        var event: [String: Any] = [
            "event": "start", "mode": mode, "stack_user": stackUser, "team": team ?? NSNull(),
            "environment": environment ?? NSNull(), "device_name": deviceName, "profile": profile.wire,
            "client_version": clientVersion ?? NSNull(),
            "record": record.map { ["user": $0.user, "install": $0.install] as Any } ?? NSNull(),
            "has_session": sessionToken != nil,
            "fresh_ids": [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()],
        ]
        // The machine ends every exchange in a few dozen steps (the longest mint registers, rotates,
        // registers again, recovers once and mints again); past the bound it is answering in a circle.
        for _ in 0..<Self.maximumSteps {
            let effect: [String: Any]
            (state, effect) = try step(state, event)
            switch effect["effect"] as? String {
            case "session_token":
                guard let sessionToken else { throw InstallAuthError.noSession }
                event = ["event": "session", "token": try await sessionToken()]
            case "public_key":
                event = ["event": "public_key", "x963": try await signer.publicKeyX963().base64EncodedString()]
            case "sign":
                let message = Data((effect["message"] as? String ?? "").utf8)
                event = ["event": "signature", "signature": try await signer.sign(message).base64EncodedString()]
            case "rotate":
                try await signer.rotate()
                event = ["event": "rotated"]
            case "post":
                event = await post(effect)
            case "save_record":
                let saved = effect["record"] as? [String: Any]
                record = (saved?["user"] as? String).flatMap { user in
                    (saved?["install"] as? String).map { InstallRecord(user: user, install: $0) }
                }
                await onRecord?(record)
                event = ["event": "saved"]
            case "done", "revoked":
                return effect
            case "fail":
                throw InstallAuthError(failure: effect)
            default:
                throw InstallAuthError.malformedReply
            }
        }
        throw InstallAuthError.malformedReply
    }

    private func post(_ effect: [String: Any]) async -> [String: Any] {
        let path = effect["path"] as? String ?? ""
        do {
            let (status, data) = try await transport.post(
                path, json: Data((effect["body"] as? String ?? "").utf8), bearer: effect["bearer"] as? String,
                headers: effect["headers"] as? [String: String] ?? [:])
            return ["event": "http", "status": status, "body": String(decoding: data, as: UTF8.self)]
        } catch {
            return ["event": "transport_error", "url_error_code": (error as? URLError)?.code.rawValue ?? NSNull()]
        }
    }

    /// One step of cmux-cloud-config's install_auth; an FFI that does not answer fails closed.
    private func step(_ state: Any, _ event: [String: Any]) throws -> (Any, [String: Any]) {
        let request: [String: Any] = ["state": state, "event": event, "now_ms": now().timeIntervalSince1970 * 1000]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let answer = CloudStartCore().callData("cloud_identity_install_auth_step", data),
              let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let effect = reply["effect"] as? [String: Any] else { throw InstallAuthError.malformedReply }
        return (reply["state"] ?? NSNull(), effect)
    }
}
