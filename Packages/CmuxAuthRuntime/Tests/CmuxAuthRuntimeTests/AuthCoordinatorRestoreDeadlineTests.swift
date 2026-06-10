import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Virtual-time tests for the bounded launch session restore.
///
/// The live `/users/me` probe is the only network call that holds the
/// "Restoring session" gate (`isRestoringSession`), and the SDK gives it no
/// deadline of its own: with WiFi up but the auth API unreachable it sits on
/// the OS-default request timeout (~60s) while the user stares at a spinner.
/// These tests drive the restore deadline with a ``ManualTestClock``, so none
/// of them wait in real time: the gate must resolve at the deadline (cached
/// session preserved, exactly like a transient network hiccup), the live token
/// store must still decide definitive sign-outs, and a probe that answers
/// before the deadline must win with no interference from the expired timer.
@MainActor
@Suite struct AuthCoordinatorRestoreDeadlineTests {
    private static let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")

    private func makeCoordinator(
        client: FakeAuthClient,
        clock: ManualTestClock,
        store: FakeKeyValueStore = FakeKeyValueStore()
    ) -> (AuthCoordinator, FakeKeyValueStore) {
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            clock: clock
        )
        return (coordinator, store)
    }

    /// A store pre-populated like a previous signed-in run, so `init` primes
    /// the coordinator into the restoring state a returning user launches into.
    private func storeWithCachedSession() throws -> FakeKeyValueStore {
        let store = FakeKeyValueStore()
        store.set(true, forKey: "has_tokens")
        try CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user").save(Self.user)
        return store
    }

    // The exact dogfooded symptom: launch with a cached session, the probe
    // hangs (auth API unreachable while WiFi is up). The restoring gate must
    // resolve at the deadline with the cached session preserved instead of
    // spinning on the OS timeout.
    @Test func launchRestoreGateResolvesAtDeadlineWhenProbeHangs() async throws {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "stale", refresh: "r", user: Self.user)
        await client.setHangOnCurrentUser(true)
        let (coordinator, store) = makeCoordinator(
            client: client,
            clock: clock,
            store: try storeWithCachedSession()
        )

        // The launch gate is up: tokens exist, identity not yet validated.
        #expect(coordinator.isRestoringSession)
        #expect(coordinator.isAuthenticated == false)

        coordinator.start()
        // Only the deadline sleeps on the manual clock (the probe parks on the
        // hung fake), so one parked sleeper means restore is genuinely waiting.
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: AuthCoordinator.defaultRestoreValidationDeadline)
        await coordinator.awaitBootstrapped()

        // Gate resolved at the deadline; the cached session is preserved (a
        // timeout proves nothing definitive, so it must not sign the user out).
        #expect(coordinator.isRestoringSession == false)
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == Self.user)
        #expect(store.bool(forKey: "has_tokens"))
    }

    // The deadline is transient-shaped, but the live token store still decides:
    // when no refresh token survives the hung probe, the session is genuinely
    // gone and the gate must route to sign-in, not resurrect the cached user.
    @Test func deadlineExpiryWithNoRefreshTokenRoutesToLogin() async throws {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "stale", refresh: nil, user: Self.user)
        await client.setHangOnCurrentUser(true)
        let (coordinator, store) = makeCoordinator(
            client: client,
            clock: clock,
            store: try storeWithCachedSession()
        )

        coordinator.start()
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: AuthCoordinator.defaultRestoreValidationDeadline)
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isRestoringSession == false)
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    // A probe that answers promptly wins the race: the restore completes as a
    // real validation, and the expired deadline later must not flip any state.
    @Test func fastProbeWinsAndExpiredDeadlineIsInert() async throws {
        let clock = ManualTestClock()
        let client = FakeAuthClient(access: "a", refresh: "r", user: Self.user)
        let (coordinator, _) = makeCoordinator(
            client: client,
            clock: clock,
            store: try storeWithCachedSession()
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == Self.user)
        #expect(coordinator.isRestoringSession == false)

        // The winner cancelled the deadline; advancing far past it must be a
        // no-op (no stray timer can sign the user out or reopen the gate).
        clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.isRestoringSession == false)
    }

    // Foreground revalidation reuses the same bounded probe: a hung probe on
    // resume resolves at the deadline without touching the live session.
    @Test func foregroundRevalidationIsBoundedByDeadline() async throws {
        let clock = ManualTestClock()
        let client = FakeAuthClient(user: Self.user)
        let (coordinator, store) = makeCoordinator(client: client, clock: clock)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        await client.setTokens(access: "stale", refresh: "r")
        await client.setHangOnCurrentUser(true)

        let revalidation = Task { await coordinator.revalidateSession() }
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: AuthCoordinator.defaultRestoreValidationDeadline)
        await revalidation.value

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == Self.user)
        #expect(store.bool(forKey: "has_tokens"))
    }
}
