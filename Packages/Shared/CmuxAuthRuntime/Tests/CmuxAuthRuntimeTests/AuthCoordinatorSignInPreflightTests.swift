import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorSignInPreflightTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    @Test func timeoutBlocksRetryUntilStaleTokenWorkFinishes() async throws {
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
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await coordinator.awaitBootstrapped()
        await coordinator.signOut()

        let firstSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await firstSignIn.value }

        let blockedRetry = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await blockedRetry.value }

        await client.releaseHangingAccessTokenProbe()
        await waitUntilTokenWorkFinished(coordinator)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)
    }

    @Test func staleValidationCleanupDoesNotDeleteRetryTokens() async throws {
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
        await client.armCompareClearGate()
        await client.releaseValidationWithStaleTokenWrite()
        await client.compareClearDidPark()

        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        await #expect(throws: AuthError.timedOut) { try await signIn.value }
        #expect(await client.refreshToken() == "stale-validation-refresh")

        await client.releaseCompareClear()
        await waitUntilTokenWorkFinished(coordinator)
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)
        #expect(await client.accessToken() == "new-access")
        #expect(await client.refreshToken() == "new-refresh")
    }

    @Test func signOutWinsWhileSignInWaitsForPreflight() async throws {
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
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await coordinator.awaitBootstrapped()

        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await Task.yield()
        await coordinator.signOut()
        await client.releaseHangingAccessTokenProbe()

        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func canceledValidationDoesNotStartReplacementTokenProbeDuringSignInPreflight() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = CancellationAwareValidationAuthClient(user: user)
        let coordinator = makeCoordinator(
            client: client,
            clock: clock,
            cachedUser: user,
            hasCachedTokens: true
        )

        let validation = Task { await coordinator.revalidateSession() }
        await client.validationDidStart()

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        await validation.value

        #expect(coordinator.isAuthenticated)
        #expect(await client.oldSessionRefreshProbeCount == 0)
    }

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock,
        cachedUser: CMUXAuthUser? = nil,
        hasCachedTokens: Bool = false
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
            clock: clock
        )
    }

    private func waitUntilTokenWorkFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeSessionValidations.isEmpty,
               coordinator.activeTokenTouchingPhases.isEmpty {
                return
            }
            await Task.yield()
        }
    }
}
