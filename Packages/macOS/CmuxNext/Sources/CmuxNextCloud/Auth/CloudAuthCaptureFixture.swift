import CMUXAuthCore
import CmuxAuthRuntime
public import Foundation
import Security
import Darwin
import CmuxNextCompat

#if DEBUG
/// A capture keeps its auth caches in memory, like a memory-only launch.
typealias CaptureFixtureKeyValueStore = MemoryAuthKeyValueStore

@MainActor
final class CaptureFixtureBrowserAuthSessionFactory: HostBrowserAuthSessionFactory {
    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession {
        CaptureFixtureBrowserAuthSession()
    }
}

@MainActor
final class CaptureFixtureBrowserAuthSession: HostBrowserAuthSession {
    func start() -> Bool { false }
    func cancel() {}
}

/// Offline auth dependencies used only by named fleet capture states. This
/// keeps the real ``CloudAuth`` coordinator and browser callback route in the
/// frame while preventing a capture from reading a developer's credentials or
/// contacting Stack Auth.
actor CaptureFixtureTokenStore: StackAuthTokenStoreProtocol {
    private var access: String?
    private var refresh: String?

    func getStoredAccessToken() async -> String? { access }
    func getStoredRefreshToken() async -> String? { refresh }
    func setTokens(accessToken: String?, refreshToken: String?) async {
        access = accessToken
        refresh = refreshToken
    }
    func clearTokens() async {
        access = nil
        refresh = nil
    }
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        guard refresh == compareRefreshToken else { return }
        refresh = newRefreshToken
        access = newAccessToken
    }
}

actor CaptureFixtureAuthClient: AuthClient {
    private let store: CaptureFixtureTokenStore

    init(store: CaptureFixtureTokenStore) { self.store = store }

    func accessToken() async -> String? { await store.getStoredAccessToken() }
    func resolvedAccessToken(forceRefresh: Bool) async throws -> String? {
        await store.getStoredAccessToken()
    }
    func refreshToken() async -> String? { await store.getStoredRefreshToken() }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        guard await store.getStoredRefreshToken() != nil else { return nil }
        if throwOnMissing { throw AuthError.networkError }
        return nil
    }
    func listTeams() async throws -> [CMUXAuthTeam] { throw AuthError.offline }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { throw AuthError.offline }
    func signInWithMagicLink(code: String) async throws { throw AuthError.offline }
    func signInWithCredential(email: String, password: String) async throws { throw AuthError.offline }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws { throw AuthError.offline }
    func storedAccessToken() async -> String? { await store.getStoredAccessToken() }
    func clearLocalSession() async { await store.clearTokens() }
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        await store.compareAndSet(compareRefreshToken: refreshToken, newRefreshToken: nil, newAccessToken: nil)
    }
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
}
#endif

public enum CaptureAuthCleanupPhase: String, Sendable {
    case prepare
    case cleanup
}

/// A non-secret proof that the exact auth stores used by this capture are absent.
public struct CaptureAuthCleanupResult: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case ok
        case invalidLease = "invalid_lease"
        case bundleMismatch = "bundle_mismatch"
        case keychainStoreUnavailable = "keychain_store_unavailable"
        case keychainItemPresent = "keychain_item_present"
        case keychainReadFailed = "keychain_read_failed"
        case fileStorePresent = "file_store_present"
        case fileDeleteFailed = "file_delete_failed"
        case markerPresent = "marker_present"
        case ownershipMissing = "ownership_missing"
        case ownershipMismatch = "ownership_mismatch"
        case markerWriteFailed = "marker_write_failed"
        case markerVerificationFailed = "marker_verification_failed"
        case authNotQuiescent = "auth_not_quiescent"
    }

    public let ok: Bool
    public let code: Code
    public let keychainAbsent: Bool
    public let filesAbsent: Bool
    public let verifiedAbsent: Bool

    public init(ok: Bool, code: Code, keychainAbsent: Bool = false, filesAbsent: Bool = false,
                verifiedAbsent: Bool = false) {
        self.ok = ok
        self.code = code
        self.keychainAbsent = keychainAbsent
        self.filesAbsent = filesAbsent
        self.verifiedAbsent = verifiedAbsent
    }

    public static func failure(_ code: Code) -> Self { Self(ok: false, code: code) }
    public static let success = Self(ok: true, code: .ok, keychainAbsent: true, filesAbsent: true, verifiedAbsent: true)
}

/// Executes Foundation/Security operations selected by Rust. Ownership, names,
/// ordering and result validation live in cmux-cloud-config::capture_auth.
public struct CaptureAuthPersistence: Sendable {
    public init() {}
    private struct Fact: Codable { var status: String; var text: String? }
    private struct Action: Decodable {
        var kind: String
        var path: String?
        var text: String?
        var service: String?
        var account: String?
        var protected: Bool?
    }
    private struct Request: Encodable {
        var phase: String, preflight: Bool, leaseId: String, bundleId: String
        var configuredBundleId: String?, home: String
        var storage: CloudConfiguration.StorageNames
        var legacy: CloudConfiguration.LegacyStore?
        var stackProjectId: String
        var facts: [Fact] = []
    }
    private struct Reply: Decodable {
        var preflightComplete: Bool
        var action: Action?
        var result: CaptureAuthCleanupResult?
    }

    public func preflight(configuration: CloudConfiguration, phase: CaptureAuthCleanupPhase,
                          leaseID: String, requestedBundleIdentifier: String,
                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CaptureAuthCleanupResult? {
        execute(configuration, phase, leaseID, requestedBundleIdentifier, homeDirectory, preflight: true)
    }
    public func run(configuration: CloudConfiguration, phase: CaptureAuthCleanupPhase,
                    leaseID: String, requestedBundleIdentifier: String,
                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CaptureAuthCleanupResult {
        execute(configuration, phase, leaseID, requestedBundleIdentifier, homeDirectory, preflight: false)
            ?? .failure(.authNotQuiescent)
    }
    private func execute(_ configuration: CloudConfiguration, _ phase: CaptureAuthCleanupPhase,
                         _ leaseID: String, _ bundle: String, _ home: URL, preflight: Bool) -> CaptureAuthCleanupResult? {
        var request = Request(phase: phase.rawValue, preflight: preflight, leaseId: leaseID, bundleId: bundle,
                              configuredBundleId: configuration.bundleID, home: home.path,
                              storage: configuration.storage, legacy: configuration.namespacedLegacyStore,
                              stackProjectId: configuration.stackProjectID)
        while let reply = CloudStartCore().call("cloud_auth_capture_next", request, as: Reply.self) {
            guard let action = reply.action else {
                if let result = reply.result { return result }
                return reply.preflightComplete ? nil : .failure(.authNotQuiescent)
            }
            request.facts.append(perform(action))
        }
        return .failure(.authNotQuiescent)
    }
    /// lstat preserves a dangling symlink as present, and distinguishes absence
    /// from an unreadable parent or invalid path. Rust decides whether to proceed.
    func captureFileStatus(_ path: String) -> String {
        var metadata = stat()
        let result = path.withCString { Darwin.lstat($0, &metadata) }
        if result == 0 { return "present" }
        return errno == ENOENT ? "absent" : "error"
    }

    private func perform(_ action: Action) -> Fact {
        switch action.kind {
        case "probe_file":
            guard let path = action.path else { return Fact(status: "error") }
            return Fact(status: captureFileStatus(path))
        case "read_marker":
            guard let path = action.path else { return Fact(status: "error") }
            do {
                let data = try Data(blockingContentsOf: URL(fileURLWithPath: path))
                return Fact(status: "present", text: String(data: data, encoding: .utf8))
            } catch let error as NSError {
                return Fact(status: error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? "absent" : "error")
            }
        case "remove_file":
            guard let path = action.path else { return Fact(status: "error") }
            do { try FileManager.checked.removeItem(at: URL(fileURLWithPath: path)); return Fact(status: "ok") }
            catch { return Fact(status: "error") }
        case "write_marker":
            guard let path = action.path, let text = action.text else { return Fact(status: "error") }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try Data(text.utf8).blockingWrite(to: url, options: [.withoutOverwriting])
                return Fact(status: "ok")
            } catch { return Fact(status: "error") }
        case "read_keychain", "remove_keychain":
            guard let service = action.service, let account = action.account, let protected = action.protected else {
                return Fact(status: "error")
            }
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service, kSecAttrAccount as String: account]
            if protected { query[kSecUseDataProtectionKeychain as String] = true }
            let status: OSStatus
            if action.kind == "remove_keychain" {
                status = LoginKeychain().withoutUI { SecItemDelete(query as CFDictionary) }
            } else {
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                status = LoginKeychain().withoutUI { SecItemCopyMatching(query as CFDictionary, &result) }
            }
            switch status {
            case errSecSuccess: return Fact(status: action.kind == "read_keychain" ? "present" : "ok")
            case errSecItemNotFound: return Fact(status: "absent")
            case errSecMissingEntitlement: return Fact(status: "unavailable")
            default: return Fact(status: "error")
            }
        default: return Fact(status: "error")
        }
    }
}
