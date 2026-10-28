import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import CmuxNextCompat

#if DEBUG
final class CaptureFixtureKeyValueStore: CMUXAuthKeyValueStore, Sendable {
    private enum Value: Sendable { case flag(Bool), data(Data), text(String) }
    private let values = Mutex<[String: Value]>([:])

    func bool(forKey defaultName: String) -> Bool {
        values.withLock { if case .flag(let value) = $0[defaultName] { return value }; return false }
    }
    func data(forKey defaultName: String) -> Data? {
        values.withLock { if case .data(let value) = $0[defaultName] { return value }; return nil }
    }
    func string(forKey defaultName: String) -> String? {
        values.withLock { if case .text(let value) = $0[defaultName] { return value }; return nil }
    }
    func set(_ value: Any?, forKey defaultName: String) {
        let stored: Value?
        switch value {
        case let flag as Bool: stored = .flag(flag)
        case let data as Data: stored = .data(data)
        case let text as String: stored = .text(text)
        default: stored = nil
        }
        values.withLock { $0[defaultName] = stored }
    }
    func removeObject(forKey defaultName: String) {
        _ = values.withLock { $0.removeValue(forKey: defaultName) }
    }
}

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
