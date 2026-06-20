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
        cachedUser: CMUXAuthUser? = nil,
        hasCachedTokens: Bool = false,
        onSignedIn: @escaping @Sendable () async -> Void = {}
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        sessionCache.setHasTokens(hasCachedTokens)
        if let cachedUser {
            try? userCache.save(cachedUser)
        }
        return AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
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

    @Test func launchRestoreTokenProbeTimeoutStopsRestoringSession() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(
            client: client,
            clock: clock,
            cachedUser: user,
            hasCachedTokens: true
        )

        #expect(coordinator.isRestoringSession)
        coordinator.start()
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        let completion = TestPhaseSignal()
        let bootstrap = Task {
            await coordinator.awaitBootstrapped()
            await completion.markStarted()
        }
        defer { bootstrap.cancel() }

        try await Task.sleep(for: .milliseconds(50))

        #expect(await completion.didStart)
        #expect(coordinator.isRestoringSession == false)
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
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

actor HangingLaunchTokenProbeAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var accessStarted = false

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func accessTokenDidStart() async {
        if accessStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func accessToken() async -> String? {
        accessStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return nil
    }

    func refreshToken() async -> String? { "refresh" }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { user }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
}
