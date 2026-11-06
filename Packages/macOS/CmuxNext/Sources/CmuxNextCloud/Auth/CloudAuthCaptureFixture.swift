import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
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
