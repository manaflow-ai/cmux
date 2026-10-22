import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The phone's two Secure Enclave P-256 keys (verify/phone-approvals.md).
///
/// - `identity` signs each link's pairing challenge with no prompt: it proves
///   this is the phone the Mac allowed, so a Stack token alone reaches nothing.
/// - `approval` signs an Allow or an answer for an agent, and every signature
///   needs the user: Face ID, or the device passcode when Face ID fails or is
///   not set up (`.userPresence`). acpmux on the Mac checks it.
///
/// Only the enclave's encrypted key blobs are stored (Keychain, this device
/// only); a private key never leaves the enclave. The simulator has no
/// enclave, so simulator builds (any configuration) and DEBUG builds use software
/// keys and ask for Face ID with an explicit `LAContext` check (`xcrun simctl` can
/// match it). Device builds of Release, Production and TestFlight without an enclave
/// have no keys: the phone stays deny-only and unpaired.
public final class PhoneKeys: @unchecked Sendable { // crash-allow: immutable after init except the lock-guarded cache
    public enum Failure: Error, Equatable {
        case unavailable
        case keychain(OSStatus)
        /// The user cancelled Face ID and the passcode.
        case cancelled
        /// Face ID or the passcode could not check the owner (`LAError` code).
        case notVerified(Int)

        /// What the phone says (never the raw error).
        public var message: String {
            switch self {
            case .unavailable: "this iPhone can't make approval keys."
            case .keychain: "this iPhone couldn't read its approval key. Try again."
            case .cancelled: "Face ID was cancelled."
            case .notVerified(let code):
                switch LAError.Code(rawValue: code) {
                case .passcodeNotSet?: "set a passcode on this iPhone to approve from it."
                case .biometryLockout?: "Face ID is locked. Unlock this iPhone with its passcode, then try again."
                case .biometryNotAvailable?, .biometryNotEnrolled?:
                    "Face ID isn't set up. Set up Face ID or a passcode on this iPhone to approve from it."
                case .authenticationFailed?: "Face ID didn't recognize you. Try again."
                case .notInteractive?: "open cmux, then try again."
                default: "Face ID couldn't check it's you. Try again."
                }
            }
        }
    }

    private let service: String
    /// Whose keys these are: `identity.<user>` / `approval.<user>` (nil: the
    /// shared `identity` / `approval` items of builds before per-user keys).
    public let userID: String?
    private let store: any DeviceSecretStore
    private let enclave: Bool
    private let lock = NSLock()
    private var cached: (identity: AnyKey, approval: AnyKey)?
    /// A stored key could not be read back and was replaced (review m8).
    private var replaced = false

    public static let defaultService = (Bundle.main.bundleIdentifier ?? "dev.cmux.mobile") + ".phone-keys"

    /// One key pair per bundle and account (a Demo and a Production install
    /// never share keys, and two accounts on one phone never share keys). The
    /// keys survive sign-out, so the same account signing in again is the
    /// phone its Macs approved (verify/persistence.md).
    ///
    /// Migration: builds before per-user keys kept one pair and deleted it on
    /// sign-out, so a pair that exists belongs to the account signed in now;
    /// the first `PhoneKeys(userID:)` adopts it.
    public convenience init(userID: String? = nil, service: String = PhoneKeys.defaultService,
                            store: any DeviceSecretStore = KeychainSecretStore()) {
        self.init(userID: userID, service: service, store: store, enclave: Self.hasEnclave)
    }

    /// `enclave` false: software keys (DEBUG or simulator builds only; tests on a Mac with an enclave).
    init(userID: String?, service: String, store: any DeviceSecretStore, enclave: Bool) {
        self.service = service
        self.userID = userID
        self.store = store
        self.enclave = enclave
        if userID != nil {
            for kind in ["identity", "approval"] { store.adopt(service: service, from: kind, to: account(kind)) }
        }
    }

    private func account(_ kind: String) -> String { userID.map { "\(kind).\($0)" } ?? kind }

    /// X9.63 (65-byte uncompressed) points as lowercase hex.
    public func publicKeys() throws -> (identity: String, approval: String) {
        let keys = try load()
        return (Self.hex(keys.identity.publicKey), Self.hex(keys.approval.publicKey))
    }

    /// Raw `r || s` over `message` with the identity key; no prompt.
    public func signIdentity(_ message: Data) throws -> Data {
        try load().identity.sign(message, context: nil)
    }

    /// Asks for Face ID (or the passcode) and returns a signer for the approval
    /// key that uses the evaluated context, so the user sees one prompt.
    /// `reason` is the line the system sheet shows. The signer returns raw `r || s`.
    public func authorizeApproval(reason: String) async throws -> @Sendable (Data) throws -> Data {
        let key = try load().approval
        let context = LAContext()
        context.localizedFallbackTitle = nil
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw Failure.cancelled
        } catch let error as LAError {
            throw Failure.notVerified(error.code.rawValue)
        }
        let unlocked = UnlockedKey(key: key, context: context)
        return { message in try unlocked.sign(message) }
    }

    /// Whether a stored key was unreadable and replaced since the last call:
    /// the Mac then asks again, and the phone says why.
    public func takeReplaced() -> Bool {
        lock.withLock {
            defer { replaced = false }
            return replaced
        }
    }

    /// "Remove This iPhone from My Macs" and account deletion: deletes both
    /// keys; the next link makes new ones, and every Mac asks again. Sign-out
    /// keeps them (verify/persistence.md).
    public func reset() {
        lock.withLock { cached = nil }
        for kind in ["identity", "approval"] {
            store.delete(service: service, account: account(kind))
        }
    }

    /// A launch while signed out, before this build ever recorded an account:
    /// the unkeyed keys of an older build belonged to a session that has ended.
    public static func discardLegacy(service: String = PhoneKeys.defaultService,
                                     store: any DeviceSecretStore = KeychainSecretStore()) {
        for kind in ["identity", "approval"] { store.delete(service: service, account: kind) }
    }

    /// Whether this account has keys on this phone (no key is made).
    public var hasStoredKeys: Bool {
        (try? store.read(service: service, account: account("identity"))) != nil
    }

    // MARK: Storage

    private func load() throws -> (identity: AnyKey, approval: AnyKey) {
        try lock.withLock {
            if let cached { return cached }
            let keys = (identity: try key("identity", presence: false), approval: try key("approval", presence: true))
            cached = keys
            return keys
        }
    }

    /// The simulator reports an enclave (`SecureEnclave.isAvailable`) but refuses to make
    /// enclave keys (LocalAuthentication -1020), so it never uses one.
    private static var hasEnclave: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    private func key(_ account: String, presence: Bool) throws -> AnyKey {
        if enclave {
            if let blob = try read(account) {
                if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) { return .enclave(key) }
                // Unreadable (say a restore onto another enclave): a new key, and the Mac asks again.
                discard(account)
            }
            var error: Unmanaged<CFError>?
            let flags: SecAccessControlCreateFlags = presence ? [.privateKeyUsage, .userPresence] : .privateKeyUsage
            let protection = presence ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard let access = SecAccessControlCreateWithFlags(nil, protection, flags, &error) else {
                throw Failure.keychain(errSecParam)
            }
            let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try write(account, made.dataRepresentation)
            return .enclave(made)
        }
        #if DEBUG || targetEnvironment(simulator)
        // DEBUG builds and simulator builds only (the simulator has no Secure Enclave, and a
        // simulator binary never runs on an iPhone): a software key in the Keychain;
        // `authorizeApproval` still asks for Face ID first. A device Release build has none.
        if let raw = try read(account) {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) { return .software(key) }
            discard(account)
        }
        let made = P256.Signing.PrivateKey()
        try write(account, made.rawRepresentation)
        return .software(made)
        #else
        throw Failure.unavailable
        #endif
    }

    /// Deletes an unreadable stored key (the caller holds the lock).
    private func discard(_ kind: String) {
        store.delete(service: service, account: account(kind))
        replaced = true
    }

    /// Tests: stores raw bytes as a key, as a damaged item would be.
    func storeRaw(_ data: Data, account kind: String) throws {
        lock.withLock { cached = nil }
        try write(kind, data)
    }

    private func read(_ kind: String) throws -> Data? {
        do {
            return try store.read(service: service, account: account(kind))
        } catch let failure as KeychainSecretStore.Failure {
            throw Failure.keychain(failure.status)
        }
    }

    private func write(_ kind: String, _ data: Data) throws {
        do {
            try store.write(data, service: service, account: account(kind))
        } catch let failure as KeychainSecretStore.Failure {
            throw Failure.keychain(failure.status)
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// The approval key with the context Face ID evaluated (used once per approval).
private final class UnlockedKey: @unchecked Sendable { // crash-allow: immutable after init
    let key: AnyKey
    let context: LAContext

    init(key: AnyKey, context: LAContext) {
        self.key = key
        self.context = context
    }

    func sign(_ message: Data) throws -> Data { try key.sign(message, context: context) }
}

private enum AnyKey {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var publicKey: Data {
        switch self {
        case .enclave(let key): key.publicKey.x963Representation
        case .software(let key): key.publicKey.x963Representation
        }
    }

    /// Raw r||s (64 bytes). An enclave key with user presence uses the already
    /// evaluated `context`, so the user sees one prompt.
    func sign(_ message: Data, context: LAContext?) throws -> Data {
        switch self {
        case .enclave(let key):
            if let context {
                let bound = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: key.dataRepresentation,
                                                                      authenticationContext: context)
                return try bound.signature(for: message).rawRepresentation
            }
            return try key.signature(for: message).rawRepresentation
        case .software(let key):
            return try key.signature(for: message).rawRepresentation
        }
    }
}
