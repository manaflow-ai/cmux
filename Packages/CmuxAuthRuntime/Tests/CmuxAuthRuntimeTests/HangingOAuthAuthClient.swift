import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose OAuth call suspends forever, like a system sign-in
/// sheet (`ASAuthorizationController` / `ASWebAuthenticationSession`) whose
/// callback never fires: the reported "sign-in spins forever, no error, no way
/// out" hang. The suspension is cancellation-aware so the suite terminates on
/// the unfixed coordinator instead of wedging CI.
actor HangingOAuthAuthClient: AuthClient {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var oauthStarted = false

    /// Suspends until the coordinator is parked inside
    /// ``signInWithOAuth(provider:anchor:)``, so tests cancel a sign-in that is
    /// genuinely in flight rather than racing its start.
    func oauthDidStart() async {
        if oauthStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        oauthStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        // Stand-in for a system auth callback that never fires.
        try await Task.sleep(for: .seconds(3600))
    }

    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
}
