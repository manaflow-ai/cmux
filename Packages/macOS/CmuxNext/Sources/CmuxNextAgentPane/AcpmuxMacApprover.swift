public import Foundation
import CryptoKit
import os
import Security
import CmuxNextCompat
public import CmuxNextWakeups

/// This Mac's approver key (peer-route approvals): the P-256 key the app signs a one-time Allow
/// with for a prompt of a peer of this Mac's acpmux (a chat opened with `--host`, which this Mac's
/// daemon mirrors over the peer link). The peer checks the signature against the public key
/// `acpmux host enroll` put in its `mac-approvers.json` (acpmux `hub/mac_approvers.rs`); only the
/// signed answer crosses the link.
///
/// The private key never leaves this process, so an agent on this Mac cannot sign with it:
/// - a signed build (``configure(keychainService:)`` with a service): a Secure Enclave key. Only its
///   encrypted blob is stored, in the data-protection Keychain under this app's access group; the
///   key itself never leaves the enclave, and no other app can read the blob. When the enclave or
///   the Keychain fails, there is no key (nothing is signed, the peer refuses the Allow) and the
///   next use tries again: a signed build never signs with another key than its enrolled one.
/// - a DEV build without a Team ID (``configure(keychainService:)`` with nil): a software key in
///   this process's memory only, new each launch (enroll again after a relaunch; the known DEV gap
///   of the person key, identity.md).
/// Before ``configure(keychainService:)``, ``shared`` has no key.
public nonisolated final class AcpmuxMacApprover: Sendable {
    // lint:allow one key per app process: the transport signs with it, the host gives its public half to the daemon
    public static let shared = AcpmuxMacApprover(mode: .unconfigured)

    /// The domain of the signed message (acpmux `mac_approvers::DOMAIN`).
    static let domain = "acpmux-mac-approver-decision-v1"
    /// How long a signed Allow counts: well under acpmux's `MAX_LIFETIME` (300 s).
    static let lifetime: TimeInterval = 120

    /// The key as bytes (so the lock's state is Sendable): a software key's raw scalar, or the
    /// Secure Enclave's encrypted blob, which only this Mac's enclave can use.
    private enum Signer: Sendable {
        case software(Data)
        case enclave(Data)

        var publicKey: P256.Signing.PublicKey {
            get throws {
                switch self {
                case .software(let raw): try P256.Signing.PrivateKey(rawRepresentation: raw).publicKey
                case .enclave(let blob): try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).publicKey
                }
            }
        }

        func sign(_ message: Data) throws -> P256.Signing.ECDSASignature {
            switch self {
            case .software(let raw): try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message)
            case .enclave(let blob): try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message)
            }
        }
    }

    /// The loaded key and what acpmux calls it.
    private struct Key: Sendable {
        let signer: Signer
        let id: String
        let publicKey: String
    }

    /// Where the key lives.
    enum Mode: Sendable {
        case unconfigured
        case memory
        case enclave(service: String)
    }

    private struct State {
        var mode: Mode
        var key: Key?
    }

    // lock carve-out: the key, loaded once off main (Keychain and enclave), read by each signing off main
    private let state: Mutex<State>
    /// Where the registration's person line places its limit (``use(deadlines:)``); main actor only.
    private let placer = DeadlinePlacer()

    /// The app's one deadline placer, for the registration's person line (``register(_:)``).
    @MainActor private final class DeadlinePlacer: Sendable {
        nonisolated init() {}
        var deadlines: MainDeadlineScheduler?
    }

    /// Gives the approver the app's one deadline placer (`AppServices.mainDeadlines`), which each
    /// daemon registration's person line places its 5 s limit on. Before it, a connect registers
    /// nothing (a test, or a host with no app).
    @MainActor public func use(deadlines: MainDeadlineScheduler) {
        placer.deadlines = deadlines
    }
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    /// A memory key (tests, and a DEV build's ``shared`` once configured).
    public convenience init() { self.init(mode: .memory) }

    init(mode: Mode) { state = Mutex(State(mode: mode)) }

    /// Where the key lives: the Keychain service of a signed build (the Secure Enclave), or nil
    /// (memory). Called once at launch; a later call changes nothing.
    public func configure(keychainService: String?) {
        state.withLock { state in
            guard case .unconfigured = state.mode else { return }
            state.mode = keychainService.map { .enclave(service: $0) } ?? .memory
        }
        // The Keychain read (or the enclave's new key) off the main actor, before the first Allow.
        // task-owner: one key load at launch, then ends
        Task.detached(priority: .utility) { [self] in _ = self.key() }
    }

    /// The key, made or loaded on first use; nil before ``configure(keychainService:)``, or when a
    /// signed build's enclave key cannot be loaded or made (tried again on the next use).
    private func key() -> Key? {
        state.withLock { state in
            if let key = state.key { return key }
            let signer: Signer?
            switch state.mode {
            case .unconfigured: signer = nil
            case .memory: signer = .software(P256.Signing.PrivateKey().rawRepresentation)
            case .enclave(let service): signer = Self.enclaveKey(service: service)
            }
            guard let signer, let point = try? signer.publicKey.x963Representation else { return nil }
            let digest = SHA256.hash(data: point).prefix(8).map { String(format: "%02x", $0) }.joined()
            let key = Key(signer: signer, id: "mac-" + digest, publicKey: Self.hex(point))
            state.key = key
            return key
        }
    }

    /// This Mac's id and public key as acpmux reads them: `mac-` and the first 16 hex digits of the
    /// SHA-256 of the 65-byte uncompressed point, and that point as lowercase hex. nil without a key.
    /// The first read may load the key from the Keychain: read it off the main actor.
    public var identity: (id: String, publicKey: String)? { key().map { ($0.id, $0.publicKey) } }

    /// ``identity``, read off the main actor.
    @concurrent func loadedIdentity() async -> (id: String, publicKey: String)? { identity }

    /// `_meta.acpmux.approverDecision` for a one-time Allow of `permission` with option `option`
    /// (`answers`: the canonical digest of a question's answers, empty for none), signed off the
    /// main actor (the enclave). nil when there is no key or it cannot sign.
    @concurrent func decision(instance: String, session: String, permission: String, toolCall: String, option: String,
                              nonce: String, answers: String, now: Date = Date()) async -> [String: any Sendable]? {
        guard let key = key() else {
            Self.logger.error("mac approver has no key: the allow goes out unsigned")
            return nil
        }
        let expiresAt = UInt64(now.timeIntervalSince1970 + Self.lifetime)
        let message = Self.message(instance: instance, mac: key.id, session: session, permission: permission,
                                   toolCall: toolCall, option: option, nonce: nonce, expiresAt: expiresAt, answers: answers)
        do {
            let signature = try key.signer.sign(message)
            return ["approver": key.id, "expiresAt": expiresAt, "signature": Self.hex(signature.rawRepresentation)]
        } catch {
            Self.logger.error("mac approver could not sign: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The signed bytes (acpmux `mac_approvers::message`): the domain, then each part after a NUL.
    static func message(instance: String, mac: String, session: String, permission: String, toolCall: String,
                        option: String, nonce: String, expiresAt: UInt64, answers: String) -> Data {
        var out = Data(domain.utf8)
        for part in [instance, mac, session, permission, toolCall, option, nonce, String(expiresAt), answers] {
            out.append(0)
            out.append(contentsOf: Data(part.utf8))
        }
        return out
    }

    /// Gives this Mac's acpmux the public key, so `acpmux host enroll` there knows which key to
    /// enroll on a peer (`_acpmux/mac_approver_set`, the person only), each time the host connects
    /// to that daemon (a restarted daemon holds none: `thisMac` is in its memory only). Off the
    /// pane's connect path.
    static func register(_ environment: AcpmuxEnvironment) {
        // task-owner: one short person connection (5 s deadline at most) per daemon connect
        Task { @MainActor in await registerNow(environment) }
    }

    @MainActor
    private static func registerNow(_ environment: AcpmuxEnvironment) async {
        AgentPanePeerApprovals.daemons[environment.socketPath] = ["ACPMUX_HOME": environment.home.path,
                                                                  "ACPMUX_SOCKET": environment.socketPath]
        guard let deadlines = shared.placer.deadlines, let identity = await shared.loadedIdentity() else { return }
        guard let line = await AcpmuxPersonLine.open(environment, deadlines: deadlines) else { return }
        defer { line.close() }
        guard line.isPerson else { return }
        let name = await MacName().displayName()
        // nil: a daemon too old for peer-route approvals, nothing to give it.
        _ = await line.call("_acpmux/mac_approver_set", ["id": identity.id, "publicKey": identity.publicKey, "name": name])
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The Secure Enclave key under `service`, made and stored on first use; nil without an
    /// enclave or when the Keychain cannot read or store it (then there is no key, and the next use
    /// tries again). A new key replaces only a missing one, or a stored blob this enclave cannot use.
    private static func enclaveKey(service: String) -> Signer? {
        guard SecureEnclave.isAvailable else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "mac-approver", kSecAttrSynchronizable as String: false,
                                    kSecUseDataProtectionKeychain as String: true]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecSuccess, let blob = out as? Data,
           (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)) != nil {
            return .enclave(blob)
        }
        // A Keychain that cannot answer now (locked, interaction not allowed): no key this time,
        // never a new one beside the enrolled one.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("mac approver key not read: \(status, privacy: .public)")
            return nil
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error),
              let made = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else { return nil }
        if status == errSecSuccess { _ = SecItemDelete(query as CFDictionary) }
        var add = query
        add[kSecValueData as String] = made.dataRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            logger.error("mac approver key not stored: \(added, privacy: .public)")
            return nil
        }
        return .enclave(made.dataRepresentation)
    }
}
