import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose server-side session revocation suspends forever,
/// like the Stack `/auth/sessions/current` DELETE on a device with no
/// connectivity (the SDK retries the idempotent DELETE with exponential
/// backoff, so offline it neither completes nor fails for minutes). The
/// suspension is cancellation-aware so the suite terminates on the unfixed
/// coordinator instead of wedging CI.
actor HangingSignOutAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var access: String?
    private var refresh: String?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var revocationStarted = false
    private(set) var revocationCancelled = false
    private(set) var localSessionCleared = false

    init(user: CMUXAuthUser) {
        self.user = user
    }

    /// Suspends until the coordinator is parked inside the hanging revocation
    /// network call, so tests assert against a sign-out that is genuinely in
    /// flight rather than racing its start.
    func revocationDidStart() async {
        if revocationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func markRevocationStarted() {
        revocationStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
    }

    /// Stand-in for the offline revocation DELETE: never returns, but responds
    /// to cancellation like URLSession does.
    private func parkForeverAsRevocation() async throws {
        markRevocationStarted()
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            revocationCancelled = true
            throw error
        }
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

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        try await parkForeverAsRevocation()
    }

    func clearLocalSession() async {
        access = nil
        refresh = nil
        localSessionCleared = true
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
        localSessionCleared = true
    }

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
