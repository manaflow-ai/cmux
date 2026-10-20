import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose magic-link send suspends forever (cancellation
/// aware), standing in for a wedged backend call on the email-code path.
actor HangingMagicLinkAuthClient: AuthClient {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendStarted = false

    /// Suspends until the coordinator is parked inside
    /// ``sendMagicLinkEmail(email:callbackURL:)``.
    func sendDidStart() async {
        if sendStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        sendStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        // Stand-in for a backend call that never resolves.
        try await Task.sleep(for: .seconds(3600))
        return "nonce"
    }

    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
