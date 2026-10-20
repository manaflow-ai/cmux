import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose teardown access-token mint (`freshAccessToken`)
/// suspends until cancelled, like the Stack `/auth/sessions/current/refresh`
/// POST on a device that went offline between the local sign-out clear and
/// the best-effort server teardown. Mirrors the production refresh path,
/// which treats cancellation as a transient failure and RETURNS `nil`
/// instead of throwing, so the caller keeps executing on a cancelled task.
actor HangingTokenMintAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var access: String?
    private var refresh: String?
    private var mintStarted = false
    private var mintStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(user: CMUXAuthUser) {
        self.user = user
    }

    /// Suspends until the coordinator is parked inside the hanging mint, so
    /// the test fires the teardown deadline against a mint that is genuinely
    /// in flight.
    func mintDidStart() async {
        if mintStarted { return }
        await withCheckedContinuation { mintStartWaiters.append($0) }
    }

    func accessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async -> String? { access }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { user }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}

    func signInWithCredential(email: String, password: String) async throws {
        access = "access"
        refresh = "refresh"
    }

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}

    func storedAccessToken() async -> String? { access }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}

    func clearLocalSession() async {
        access = nil
        refresh = nil
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? {
        mintStarted = true
        for waiter in mintStartWaiters { waiter.resume() }
        mintStartWaiters = []
        // Park until the teardown deadline cancels this task, then swallow
        // the cancellation into `nil` exactly like the production refresh
        // path (it treats cancellation as a transient failure and returns).
        try? await Task.sleep(for: .seconds(3600))
        return nil
    }
}
