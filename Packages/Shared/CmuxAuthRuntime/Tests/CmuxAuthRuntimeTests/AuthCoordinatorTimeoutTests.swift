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

    @Test func timedOutAuthPhaseDoesNotStartSecondStuckOperation() async {
        let clock = ManualTestClock()
        let client = ReleasableCancellationIgnoringMagicLinkAuthClient()
        let coordinator = makeCoordinator(client: client, clock: clock)

        let firstSend = Task { try await coordinator.sendCode(to: "a@b.com") }
        await client.waitForStartCount(1)
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        await #expect(throws: AuthError.timedOut) { try await firstSend.value }
        #expect(coordinator.isLoading == false)

        let secondSend = Task { try await coordinator.sendCode(to: "a@b.com") }
        await #expect(throws: AuthError.timedOut) { try await secondSend.value }
        #expect(await client.startCount == 1)

        await client.release()
    }

    @Test func cancelledAuthPhaseDoesNotStartSecondStuckOperation() async {
        let clock = ManualTestClock()
        let client = ReleasableCancellationIgnoringMagicLinkAuthClient()
        let coordinator = makeCoordinator(client: client, clock: clock)

        let firstSend = Task { try await coordinator.sendCode(to: "a@b.com") }
        await client.waitForStartCount(1)
        firstSend.cancel()
        await #expect(throws: AuthError.cancelled) { try await firstSend.value }
        #expect(coordinator.isLoading == false)

        let secondSend = Task { try await coordinator.sendCode(to: "a@b.com") }
        await #expect(throws: AuthError.timedOut) { try await secondSend.value }
        #expect(await client.startCount == 1)

        await client.release()
    }

    @Test func timedOutCredentialExchangeIsCancelledBeforeItCanWriteTokens() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        await client.armCredentialGate()
        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        await #expect(throws: AuthError.timedOut) { try await signIn.value }
        #expect(coordinator.isLoading == false)
        #expect(coordinator.activeSignInExchanges.count == 1)

        let retry = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await retry.value }
        #expect(await client.credentialStartCount == 1)
        #expect(coordinator.activeSignInExchanges.count == 1)

        await client.releaseParkedCredential()
        await waitUntilSignInExchangeCleanupFinished(coordinator)
        await waitUntilTokensCleared(client)

        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func timedOutCredentialExchangeClearsTokensWrittenByLateExchange() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        await client.setCredentialExchangeIgnoresCancellation(true)
        await client.armCredentialGate()
        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        await #expect(throws: AuthError.timedOut) { try await signIn.value }
        await client.releaseParkedCredential()
        await waitUntilSignInExchangeCleanupFinished(coordinator)
        await waitUntilTokensCleared(client)

        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func cancelledCredentialExchangeDoesNotStartSecondStuckExchange() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        await client.armCredentialGate()
        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()
        signIn.cancel()
        await #expect(throws: AuthError.cancelled) { try await signIn.value }
        #expect(coordinator.isLoading == false)

        let retry = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await retry.value }
        #expect(await client.credentialStartCount == 1)

        await client.releaseParkedCredential()
        await waitUntilTokensCleared(client)

        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func timedOutSessionValidationDoesNotStartSecondStuckTokenProbe() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(
            client: client,
            clock: clock,
            cachedUser: user,
            hasCachedTokens: true
        )

        coordinator.start()
        await client.waitForAccessStartCount(1)
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await coordinator.awaitBootstrapped()
        #expect(await client.accessStartCount == 1)

        let retry = Task { await coordinator.revalidateSession() }
        await retry.value

        #expect(await client.accessStartCount == 1)
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        await client.releaseHangingAccessTokenProbe()
        await waitUntilValidationCleanupFinished(coordinator)
    }

    @Test func cancelledAccessTokenCallCancelsUnderlyingTokenPhase() async {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = CancellationAwareAccessTokenAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        let accessToken = Task { try await coordinator.accessToken() }
        await client.accessDidStart()
        accessToken.cancel()

        await #expect(throws: CancellationError.self) { try await accessToken.value }
        await client.accessDidCancel()
        await client.releaseAccessToken()
        await waitUntilTokenTouchingCleanupFinished(coordinator)
    }

    @Test func timedOutAccessTokenCallDoesNotStartSecondStuckTokenPhase() async {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        let first = Task { try await coordinator.accessToken() }
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await first.value }

        let second = Task { try await coordinator.accessToken() }
        await #expect(throws: AuthError.timedOut) { try await second.value }
        #expect(await client.accessStartCount == 1)

        await client.releaseHangingAccessTokenProbe()
        await waitUntilTokenTouchingCleanupFinished(coordinator)
    }

    @Test func timedOutAccessTokenPhaseRetriesAfterBoundedReset() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)
        coordinator.tokenTouchingTimedOutResetNanoseconds = 0

        let first = Task { try await coordinator.accessToken() }
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await first.value }

        let second = Task { try await coordinator.accessToken() }
        await #expect(throws: AuthError.timedOut) { try await second.value }
        #expect(await client.accessStartCount == 1)

        await client.releaseHangingAccessTokenProbe()
        await waitUntilTokenTouchingCleanupFinished(coordinator)

        await #expect(throws: AuthError.networkError) {
            try await coordinator.accessToken()
        }
        #expect(await client.accessStartCount == 2)
    }

    @Test func timedOutSessionValidationCannotRestoreTokensAfterSignOut() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = ParkedValidationTokenRefreshAuthClient(user: user)
        let coordinator = makeCoordinator(
            client: client,
            clock: clock,
            cachedUser: user,
            hasCachedTokens: true
        )

        let validation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await validation.value

        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)

        await client.releaseValidationWithStaleTokenWrite()
        await waitUntilTokensCleared(client)

        #expect(coordinator.isAuthenticated == false)
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
    }

    @Test func lateDeadlineCannotPoisonCompletedAuthPhase() async {
        let registry = AuthPhaseTimeoutRegistry()
        let race = AuthPhaseTimeoutRace()
        let id = UUID()
        #expect(await registry.canBegin(.sendCode))
        #expect(await registry.begin(.sendCode, id: id))
        #expect(await registry.canBegin(.sendCode) == false)
        #expect(await race.winOperation())
        #expect(await race.winTimeout() == false)
        await registry.markTimedOut(.sendCode, id: id)
        #expect(await registry.canBegin(.sendCode) == false)
        await registry.end(.sendCode, id: id)
        #expect(await registry.canBegin(.sendCode))
    }

    @Test func timedOutAuthPhaseRegistryRetriesAfterBoundedReset() async {
        let registry = AuthPhaseTimeoutRegistry(timedOutResetNanoseconds: 0)
        let first = UUID()
        #expect(await registry.begin(.sendCode, id: first))
        await registry.markTimedOut(.sendCode, id: first)
        #expect(await registry.canBegin(.sendCode))

        let second = UUID()
        #expect(await registry.begin(.sendCode, id: second))
        await registry.end(.sendCode, id: second)
        #expect(await registry.canBegin(.sendCode))
    }

    @Test func completedAuthPhaseClearsRegistryBeforeResumingCaller() async throws {
        let registry = AuthPhaseTimeoutRegistry()
        let clock = ManualTestClock()
        let log = AuthDebugLog()

        let first = try await withAuthPhaseTimeout(
            .validateSession,
            duration: .seconds(1),
            clock: clock,
            log: log,
            registry: registry,
            blocksRetriesWhileTimedOutOperationActive: true
        ) {
            "first"
        }
        #expect(first == "first")
        #expect(await registry.canBegin(.validateSession))

        let second = try await withAuthPhaseTimeout(
            .validateSession,
            duration: .seconds(1),
            clock: clock,
            log: log,
            registry: registry,
            blocksRetriesWhileTimedOutOperationActive: true
        ) {
            "second"
        }
        #expect(second == "second")
    }

    @Test func launchRestoreTokenProbeTimeoutKeepsCachedSessionInteractive() async throws {
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
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
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

        await completion.waitUntilStarted()

        #expect(await completion.didStart)
        #expect(coordinator.isRestoringSession == false)
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        await client.releaseHangingAccessTokenProbe()
        await waitUntilValidationCleanupFinished(coordinator)
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

    private func waitUntilTokensCleared(_ client: GateableValidationAuthClient) async {
        for _ in 0..<100 {
            if await client.accessToken() == nil, await client.refreshToken() == nil {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilTokensCleared(_ client: ParkedValidationTokenRefreshAuthClient) async {
        for _ in 0..<100 {
            if await client.accessToken() == nil, await client.refreshToken() == nil {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilValidationCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeSessionValidations.isEmpty {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilSignInExchangeCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeSignInExchanges.isEmpty {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilTokenTouchingCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeTokenTouchingPhases.isEmpty {
                return
            }
            await Task.yield()
        }
    }

}
