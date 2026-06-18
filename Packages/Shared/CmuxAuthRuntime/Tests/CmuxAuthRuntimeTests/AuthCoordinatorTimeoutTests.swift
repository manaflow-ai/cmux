import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorTimeoutTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock,
        onSignedIn: @escaping @Sendable () async -> Void = {}
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: Self.testTimeouts,
            clock: clock,
            onSignedIn: onSignedIn
        )
    }

    @Test func stuckOAuthCallbackTimesOutAndStopsLoading() async {
        // The reported hang: a system auth callback that never fires. The
        // interactive deadline must end the flow as the localized, retryable
        // .timedOut with the spinner gone.
        let clock = ManualTestClock()
        let client = HangingOAuthAuthClient()
        let coordinator = makeCoordinator(client: client, clock: clock)

        let signIn = Task { try await coordinator.signInWithApple() }
        await client.oauthDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.interactiveFlow)

        await #expect(throws: AuthError.timedOut) { try await signIn.value }
        #expect(coordinator.isLoading == false)
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func wedgedSendCodeCallTimesOutAndStopsLoading() async {
        let clock = ManualTestClock()
        let client = HangingMagicLinkAuthClient()
        let coordinator = makeCoordinator(client: client, clock: clock)

        let send = Task { try await coordinator.sendCode(to: "a@b.com") }
        await client.sendDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        await #expect(throws: AuthError.timedOut) { try await send.value }
        #expect(coordinator.isLoading == false)
    }

    @Test func promptPhasesWinTheirDeadlinesWithoutAdvancingTime() async throws {
        // A responsive client must complete every phase with the virtual clock
        // frozen at zero: the win path cancels and joins the deadline child, so
        // this would hang (and fail by suite timeout) if cleanup regressed.
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.isLoading == false)
    }

    @Test func hungPostSignInHookIsBoundedAndDoesNotFailSignIn() async throws {
        // The post-sign-in hook runs while isLoading is still true; a hook that
        // never returns must hit its deadline and be tolerated, not hold the
        // spinner or unwind the already-published session.
        let clock = ManualTestClock()
        let hookStarted = TestPhaseSignal()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock) {
            await hookStarted.markStarted()
            // Stand-in for a side effect that never returns.
            try? await Task.sleep(for: .seconds(3600))
        }

        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await hookStarted.waitUntilStarted()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        try await signIn.value
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.isLoading == false)
    }

    @Test func timedOutIsRetryableNotSessionClearing() {
        // A timeout during cached-session validation must preserve the session
        // (transient), unlike a definitive .unauthorized.
        #expect(AuthError.timedOut.cachedSessionValidationFailureAction == .preserveCachedSession)
    }
}
