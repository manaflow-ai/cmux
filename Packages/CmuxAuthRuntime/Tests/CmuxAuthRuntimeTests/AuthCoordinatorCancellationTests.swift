import CMUXAuthCore
import Foundation
import Testing
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

    func signOut() async throws {}
}

@MainActor
@Suite struct AuthCoordinatorCancellationTests {
    private func makeCoordinator(client: any AuthClient) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
    }

    @Test func taskCancellationMapsToCancelledNotGenericError() {
        // Backing out of a stuck sign-in is not a failure: it must map to
        // .cancelled (which the UI silently ignores), not the generic
        // "Something went wrong" server error.
        #expect(AuthError(displaySafe: CancellationError()) == .cancelled)
    }

    @Test func cancellingInFlightOAuthSignInThrowsCancelledAndStopsLoading() async {
        let client = HangingOAuthAuthClient()
        let coordinator = makeCoordinator(client: client)

        let signIn = Task { try await coordinator.signInWithApple() }
        await client.oauthDidStart()
        signIn.cancel()

        await #expect(throws: AuthError.cancelled) { try await signIn.value }
        #expect(coordinator.isLoading == false)
    }
}
