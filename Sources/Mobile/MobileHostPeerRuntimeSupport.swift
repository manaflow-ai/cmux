import CMUXMobileCore
import CmuxPeerTransport
import CmuxPeerTransportCore
import CryptoKit
import Foundation
import Security

/// Errors thrown by the peer host runtime's activation and settings paths.
enum MobileHostPeerRuntimeError: Error, Equatable {
    case inactive
    case invalidLocalBinding
    case invalidBrokerBaseURL
    case brokerCooldownActive
    case registrationIncomplete
    case homeRelayUnhealthy
    case settingsUnavailable
}

/// Stable per-account, per-tag app instance identifier, stored under the same
/// UserDefaults keys as the previous transport so existing installs keep
/// their identity scope (and therefore their EndpointID) across the engine
/// swap.
struct MobileHostPeerAppInstanceStore: Sendable {
    private static let activeScopeKey = "cmux.iroh.app-instance.scope.v1"
    private static let identifierKey = "cmux.iroh.app-instance.id.v1"

    func appInstanceID(accountID: String, tag: String) throws -> String {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              Self.isSafeTag(tag) else {
            throw MobileHostPeerRuntimeError.invalidLocalBinding
        }
        let defaults = UserDefaults.standard
        let scope = Self.scope(accountID: accountID, tag: tag)
        if defaults.string(forKey: Self.activeScopeKey) == scope,
           let existing = defaults.string(forKey: Self.identifierKey),
           Self.isCanonicalUUID(existing) {
            return existing
        }
        let identifier = UUID().uuidString.lowercased()
        defaults.set(scope, forKey: Self.activeScopeKey)
        defaults.set(identifier, forKey: Self.identifierKey)
        return identifier
    }

    /// Removes the active app instance during sign-out or local revocation.
    func deactivate() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.activeScopeKey)
        defaults.removeObject(forKey: Self.identifierKey)
    }

    private static func scope(accountID: String, tag: String) -> String {
        let transcript = Data("cmux/iroh/app-instance-scope/v1\0\(accountID)\0\(tag)".utf8)
        let digest = Array(SHA256.hash(data: transcript))
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(digest.count * 2)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func isSafeTag(_ tag: String) -> Bool {
        let bytes = Array(tag.utf8)
        guard (1 ... 64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }
}

/// Relay-policy record persistence pointed at the previous transport's
/// storage location, so the signed-policy rollback floor survives the engine
/// swap. DEBUG builds use the tagged development file directory; release
/// builds use the data-protection Keychain item.
struct MobileHostPeerRelayPolicyStore: PeerRelayPolicyStoring {
    private static let service = "com.cmuxterm.iroh.relay-policy.v1"
    private static let account = "managed-relay-policy"

    #if DEBUG
    private var fileURL: URL {
        MobileHostPeerRuntime.developmentStoreDirectory(service: "relay-policy")
            .appendingPathComponent(Self.account, isDirectory: false)
    }

    func readRecord() async throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    func writeRecord(_ data: Data) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    func removeAll() async throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
            return
        }
    }
    #else
    func readRecord() async throws -> Data? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw MobileHostPeerRuntimeError.settingsUnavailable
        }
    }

    func writeRecord(_ data: Data) async throws {
        var query = Self.baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MobileHostPeerRuntimeError.settingsUnavailable
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MobileHostPeerRuntimeError.settingsUnavailable
        }
    }

    func removeAll() async throws {
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileHostPeerRuntimeError.settingsUnavailable
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    #endif
}

/// In-memory revocation intent captured before account state is wiped, so a
/// best-effort broker revoke can still be signed after sign-out clears the
/// Keychain. The previous transport also persisted this to a durable outbox;
/// that replay path is deliberately deferred.
struct MobileHostPeerSignOutPreparation: Sendable {
    let accountID: String
    let clientNamespace: String
    let bindingID: String?
    let identity: PeerEndpointIdentity?
    let endpointID: CmxIrohPeerIdentity?
}

/// Everything owned by one successful activation: the broker client bound to
/// one account pin, the registered binding, the inbound listener, and the
/// per-session and relay-refresh tasks. Torn down as one unit.
@MainActor
final class MobileHostPeerActiveRuntime {
    let accountID: String
    let revision: UInt64
    let tag: String
    let clientNamespace: String
    let broker: PeerTrustBrokerClient
    let binding: PeerBrokerBinding
    let identity: PeerEndpointIdentity
    let admission: PeerAdmissionController
    let listener: PeerInboundListener
    var generation: PeerTransportGeneration
    var watchdog: PeerEndpointHealthWatchdog<ContinuousClock>?
    var relayRefreshTask: Task<Void, Never>?
    var sessionTasks: [UUID: Task<Void, Never>] = [:]
    var appliedRelayConfigs: [PeerRelayConfig]
    var relayPolicySource: CmxIrohSettingsSnapshot.PolicySource
    var relayPolicySequence: Int64?
    var relayPolicyExpiresAt: Date?

    init(
        accountID: String,
        revision: UInt64,
        tag: String,
        clientNamespace: String,
        broker: PeerTrustBrokerClient,
        binding: PeerBrokerBinding,
        identity: PeerEndpointIdentity,
        admission: PeerAdmissionController,
        listener: PeerInboundListener,
        generation: PeerTransportGeneration,
        appliedRelayConfigs: [PeerRelayConfig],
        relayPolicySource: CmxIrohSettingsSnapshot.PolicySource,
        relayPolicySequence: Int64?,
        relayPolicyExpiresAt: Date?
    ) {
        self.accountID = accountID
        self.revision = revision
        self.tag = tag
        self.clientNamespace = clientNamespace
        self.broker = broker
        self.binding = binding
        self.identity = identity
        self.admission = admission
        self.listener = listener
        self.generation = generation
        self.appliedRelayConfigs = appliedRelayConfigs
        self.relayPolicySource = relayPolicySource
        self.relayPolicySequence = relayPolicySequence
        self.relayPolicyExpiresAt = relayPolicyExpiresAt
    }
}


#if DEBUG
/// File-backed identity persistence for tagged DEBUG bundles, mirroring the
/// previous transport's development store so tagged dev builds keep their
/// endpoint identity without Keychain prompts.
actor MobileHostPeerDevelopmentIdentityStore: PeerSecureBlobStoring {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func read(account: String) async -> PeerSecureReadResult {
        let url = fileURL(account: account)
        guard let data = try? Data(contentsOf: url) else {
            return .absent
        }
        return .found(data)
    }

    func write(_ data: Data, account: String) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL(account: account), options: [.atomic])
    }

    func delete(account: String) async throws {
        try? FileManager.default.removeItem(at: fileURL(account: account))
    }

    func deleteAll() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(account: String) -> URL {
        directory.appendingPathComponent(account, isDirectory: false)
    }
}
#endif
