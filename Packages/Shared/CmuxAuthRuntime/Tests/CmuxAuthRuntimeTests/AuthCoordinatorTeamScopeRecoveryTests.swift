import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

/// A signed-in session whose team list never loaded has no team scope, and
/// every scope-gated service (the iOS pairing host, Cloud) stays down. macOS
/// has no foreground revalidation, so the coordinator itself must retry until
/// the team list loads instead of waiting for an app restart.
@MainActor
@Suite struct AuthCoordinatorTeamScopeRecoveryTests {
    private static let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
    private static let team = CMUXAuthTeam(id: "team-1", displayName: "Team")
    /// Phase deadlines far past any backoff, so the backoff sleep is the only
    /// sleeper due within ``backoffWindow``.
    private static let longPhaseTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(3600),
        network: .seconds(3600),
        sessionRestore: .seconds(3600)
    )
    private static let backoffWindow = Duration.seconds(60)

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock,
        cachedSession: Bool = true,
        networkRestorations: FakeAuthNetworkRestorations = FakeAuthNetworkRestorations()
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        if cachedSession {
            sessionCache.setHasTokens(true)
            try? userCache.save(Self.user)
        }
        return AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: Self.longPhaseTimeouts,
            clock: clock,
            networkRestorations: networkRestorations
        )
    }

    /// Runs the whole fast backoff while the team fetch keeps failing, and
    /// returns once the loop waits at the capped backoff.
    private func exhaustRecoveryBackoff(
        clock: ManualTestClock,
        networkRestorations: FakeAuthNetworkRestorations
    ) async {
        for attempt in 0..<AuthCoordinator.teamScopeRecoveryAttemptLimit {
            await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
            clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: attempt))
        }
        await networkRestorations.waitUntilWaiting()
    }

    private func awaitTeamScope(_ coordinator: AuthCoordinator) async -> AuthenticatedTeamScope? {
        for await scope in coordinator.authenticatedTeamScopes() where scope != nil {
            return scope
        }
        return nil
    }

    @Test func failedLaunchTeamFetchRecoversWithoutRestart() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.authenticatedTeamScope == nil)

        await client.setThrowOnListTeams(nil)
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    @Test func transientLaunchValidationFailureRecoversTeamScope() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnCurrentUser(URLError(.networkConnectionLost))
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.authenticatedTeamScope == nil)

        await client.setThrowOnCurrentUser(nil)
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    /// The first 2 s backoff may end 200 ms late, so its wake can share one the kernel already has.
    @Test func recoveryBackoffSleepsWithLeeway() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)

        let firstDelay = AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0)
        #expect(firstDelay == .seconds(2))
        #expect(clock.sleepTolerances.contains(.milliseconds(200)))
        coordinator.cancelTeamScopeRecovery()
    }

    @Test func recoveryKeepsRetryingWhileTeamFetchFails() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        // The first retry also fails; the loop must schedule the next one.
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        #expect(coordinator.authenticatedTeamScope == nil)
        await client.setThrowOnListTeams(nil)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 1))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    /// An offline Mac must not wake every 60 s for the whole session: the
    /// fast backoff ends after its bound, and the network path coming back
    /// starts it again at the initial delay.
    @Test func recoverySlowsAfterItsBoundAndRestartsWhenTheNetworkReturns() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never slowed or never restarted" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let networkRestorations = FakeAuthNetworkRestorations()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock, networkRestorations: networkRestorations)
        coordinator.start()
        await coordinator.awaitBootstrapped()

        await exhaustRecoveryBackoff(clock: clock, networkRestorations: networkRestorations)
        await clock.waitUntilSleeper(dueWithin: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        #expect(clock.hasSleeper(dueWithin: Self.backoffWindow) == false)
        #expect(coordinator.hasPendingTeamScopeRecovery)
        #expect(coordinator.authenticatedTeamScope == nil)

        // The path comes back while the server still fails: an immediate
        // check, then a new streak from the 2 s delay.
        networkRestorations.restore()
        await clock.waitUntilSleeper(dueWithin: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))
        await client.setThrowOnListTeams(nil)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    /// A server that keeps failing on a working network: the path never
    /// changes, so no restoration comes, and the capped backoff still retries.
    @Test func serverErrorsOnAWorkingNetworkKeepRetryingAtTheCappedBackoff() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery stopped retrying on a working network" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let networkRestorations = FakeAuthNetworkRestorations()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(StackAuthError(code: "INTERNAL_SERVER_ERROR", message: "500"))
        let coordinator = makeCoordinator(client: client, clock: clock, networkRestorations: networkRestorations)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        await exhaustRecoveryBackoff(clock: clock, networkRestorations: networkRestorations)
        #expect(coordinator.authenticatedTeamScope == nil)

        // Still failing at the first capped retry: the loop waits again.
        await clock.waitUntilSleeper(dueWithin: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        let fetches = await client.listTeamsCount
        clock.advance(by: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        await clock.waitUntilSleeper(dueWithin: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        #expect(await client.listTeamsCount == fetches + 1)
        #expect(coordinator.authenticatedTeamScope == nil)

        await client.setThrowOnListTeams(nil)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    /// A 429 on the last check of the fast streak: neither a restored path
    /// nor a host trigger may check before its Retry-After has passed.
    @Test func rateLimitThatEndsTheStreakHoldsTheNextCheck() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never retried after the 429" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let networkRestorations = FakeAuthNetworkRestorations()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock, networkRestorations: networkRestorations)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        let lastAttempt = AuthCoordinator.teamScopeRecoveryAttemptLimit - 1
        for attempt in 0..<lastAttempt {
            await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
            clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: attempt))
        }
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        let retryAfter = Duration.seconds(600)
        await client.setThrowOnListTeams(StackAuthError(
            code: "RATE_LIMITED",
            message: "429",
            details: [StackAuthError.retryAfterSecondsKey: TimeInterval(600)]
        ))
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: lastAttempt))
        await networkRestorations.waitUntilWaiting()
        #expect(coordinator.teamScopeRateLimit != nil)
        let fetches = await client.listTeamsCount
        await client.setThrowOnListTeams(nil)

        await coordinator.recoverTeamScopeIfNeeded()
        #expect(await client.listTeamsCount == fetches)

        // The capped timer and the rest of the 429 delay both wait; neither
        // ends before Retry-After.
        networkRestorations.restore()
        await clock.waitUntilSleepers(count: 2)
        #expect(clock.hasSleeper(dueWithin: retryAfter - .seconds(1)) == false)
        #expect(await client.listTeamsCount == fetches)
        #expect(coordinator.authenticatedTeamScope == nil)

        clock.advance(by: AuthCoordinator.teamScopeRecoveryMaximumDelay)
        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    @Test func hostTriggerRestartsARecoveryAtTheCappedBackoff() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "a host trigger did not restart the capped recovery" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let networkRestorations = FakeAuthNetworkRestorations()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock, networkRestorations: networkRestorations)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        await exhaustRecoveryBackoff(clock: clock, networkRestorations: networkRestorations)

        await coordinator.recoverTeamScopeIfNeeded()
        #expect(coordinator.hasPendingTeamScopeRecovery)
        await clock.waitUntilSleeper(dueWithin: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))
        await client.setThrowOnListTeams(nil)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    @Test func signOutStopsRecovery() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        #expect(coordinator.hasPendingTeamScopeRecovery)

        coordinator.clearAuthState()
        #expect(coordinator.hasPendingTeamScopeRecovery == false)
    }

    @Test func validationTimeoutAtLaunchRecoversTeamScope() async {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnCurrentUser(AuthError.timedOut)
        let coordinator = makeCoordinator(client: client, clock: clock)

        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.authenticatedTeamScope == nil)
        #expect(coordinator.hasPendingTeamScopeRecovery)

        await client.setThrowOnCurrentUser(nil)
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    @Test func signInWithFailedTeamFetchRecoversTeamScope() async throws {
        let watchdog = failAfterDeadline(.seconds(60)) { "team-scope recovery never scheduled a retry" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.timedOut))
        let coordinator = makeCoordinator(client: client, clock: clock, cachedSession: false)
        coordinator.start()
        await coordinator.awaitBootstrapped()

        try await coordinator.signInWithGitHub()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.authenticatedTeamScope == nil)
        #expect(coordinator.hasPendingTeamScopeRecovery)

        await client.setThrowOnListTeams(nil)
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
    }

    @Test func hostTriggerRecoversWithoutWaitingForBackoff() async {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.authenticatedTeamScope == nil)

        await client.setThrowOnListTeams(nil)
        await coordinator.recoverTeamScopeIfNeeded()

        #expect(coordinator.authenticatedTeamScope?.teamID == Self.team.id)
    }

    @Test func hostTriggerIsNoOpForHealthySession() async {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        let coordinator = makeCoordinator(client: client, clock: clock)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.authenticatedTeamScope != nil)
        #expect(coordinator.hasPendingTeamScopeRecovery == false)

        // A healthy session must not revalidate on every activation or wake.
        await client.setThrowOnCurrentUser(URLError(.notConnectedToInternet))
        await coordinator.recoverTeamScopeIfNeeded()
        #expect(coordinator.authenticatedTeamScope != nil)
        #expect(coordinator.hasPendingTeamScopeRecovery == false)
    }

    @Test func successfulHostRecoveryClearsPendingBackoffImmediately() async {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.hasPendingTeamScopeRecovery)

        await client.setThrowOnListTeams(nil)
        await coordinator.recoverTeamScopeIfNeeded()

        #expect(coordinator.authenticatedTeamScope?.teamID == Self.team.id)
        #expect(coordinator.hasPendingTeamScopeRecovery == false)
        coordinator.clearAuthState()
    }

    @Test func newSignInStartsRecoveryAtTheInitialDelay() async throws {
        let watchdog = failAfterDeadline(.seconds(5)) { "new sign-in inherited the previous session's recovery backoff" }
        defer { watchdog.cancel() }
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: Self.user)
        await client.setTeams([Self.team])
        await client.setThrowOnListTeams(URLError(.notConnectedToInternet))
        let coordinator = makeCoordinator(client: client, clock: clock)
        coordinator.start()
        await coordinator.awaitBootstrapped()

        // Leave the old session parked at the maximum 60-second delay.
        for attempt in 0..<5 {
            await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
            clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: attempt))
        }
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        try await coordinator.signInWithGitHub()
        #expect(coordinator.authenticatedTeamScope == nil)
        await client.setThrowOnListTeams(nil)
        await clock.waitUntilSleeper(dueWithin: Self.backoffWindow)
        clock.advance(by: AuthCoordinator.teamScopeRecoveryDelay(afterAttempt: 0))

        let scope = await awaitTeamScope(coordinator)
        #expect(scope?.teamID == Self.team.id)
        coordinator.clearAuthState()
    }
}
