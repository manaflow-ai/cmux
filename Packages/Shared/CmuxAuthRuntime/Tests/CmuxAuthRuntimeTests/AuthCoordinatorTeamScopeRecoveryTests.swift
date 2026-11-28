import CMUXAuthCore
import Foundation
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
        cachedSession: Bool = true
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
            clock: clock
        )
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
