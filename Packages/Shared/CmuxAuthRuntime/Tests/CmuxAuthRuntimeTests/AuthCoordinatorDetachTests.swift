import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// ``AuthCoordinator/detachSessionLeavingTokens()`` — the "park" half of a
/// backend-environment switch: it must end the published session exactly like
/// sign-out's local clear while leaving the token store byte-for-byte intact
/// (no `clearLocalSession`, no `revokeSession`, no sign-out hook).
@MainActor
@Suite struct AuthCoordinatorDetachTests {
    private let user = CMUXAuthUser(
        id: "park-user",
        primaryEmail: "aziz@manaflow.ai",
        displayName: "Aziz"
    )

    private func makeCoordinator(
        client: FakeAuthClient,
        store: FakeKeyValueStore = FakeKeyValueStore()
    ) -> (AuthCoordinator, FakeKeyValueStore) {
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        return (coordinator, store)
    }

    @Test func detachClearsPublishedStateButLeavesTokenStoreUntouched() async throws {
        let client = FakeAuthClient(refresh: "parked-refresh", user: user)
        let (coordinator, store) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "aziz@manaflow.ai", password: "pw")
        #expect(coordinator.isAuthenticated)
        #expect(store.bool(forKey: "has_tokens"))
        let accessBefore = await client.storedAccessToken()
        try #require(accessBefore != nil)

        await coordinator.detachSessionLeavingTokens()

        // Published state + self-healing caches cleared, like sign-out...
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(coordinator.availableTeams.isEmpty)
        #expect(coordinator.selectedTeamID == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(store.data(forKey: "cached_user") == nil)
        // ...but the token store is untouched and nothing was revoked.
        let clears = await client.clearLocalSessionCount
        let revokes = await client.revokeCount
        #expect(clears == 0)
        #expect(revokes == 0)
        let access = await client.storedAccessToken()
        let refresh = await client.refreshToken()
        #expect(access == accessBefore)
        #expect(refresh == "parked-refresh")
    }

    @Test func detachAdvancesSessionGenerationAndPublishesSignedOutIdentity() async throws {
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "aziz@manaflow.ai", password: "pw")
        let generationBefore = coordinator.authSessionGeneration
        let stream = coordinator.authenticatedSessionIdentities()
        var iterator = stream.makeAsyncIterator()
        // First element is the current (signed-in) identity.
        let first = await iterator.next()
        #expect(first.flatMap { $0 } != nil)

        await coordinator.detachSessionLeavingTokens()

        #expect(coordinator.authSessionGeneration > generationBefore)
        // The detach published a signed-out identity to live consumers.
        let next = await iterator.next()
        #expect(next != nil)
        #expect(next.flatMap { $0 } == nil)
    }

    @Test func detachIsSafeWhenAlreadySignedOut() async throws {
        let client = FakeAuthClient()
        let (coordinator, store) = makeCoordinator(client: client)
        #expect(coordinator.isAuthenticated == false)

        await coordinator.detachSessionLeavingTokens()

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        let clears = await client.clearLocalSessionCount
        let revokes = await client.revokeCount
        #expect(clears == 0)
        #expect(revokes == 0)
    }
}

/// ``AuthCoordinator/waitForNextSignedInUser()`` — the awaitable "next user"
/// primitive the switch transaction's restore/prompt steps are built on.
@MainActor
@Suite struct AuthCoordinatorWaitForNextSignedInUserTests {
    private let user = CMUXAuthUser(
        id: "wait-user",
        primaryEmail: "aziz@manaflow.ai",
        displayName: "Aziz"
    )

    private func makeCoordinator(client: FakeAuthClient) -> AuthCoordinator {
        AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: FakeKeyValueStore(), key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: FakeKeyValueStore(), key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: FakeKeyValueStore(),
                key: "selected_team"
            ),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
    }

    @Test func returnsCurrentUserImmediatelyWhenAuthenticated() async throws {
        let client = FakeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "aziz@manaflow.ai", password: "pw")

        let resolved = await coordinator.waitForNextSignedInUser()
        #expect(resolved == user)
    }

    @Test func suspendsUntilTheNextSignInPublishes() async throws {
        let client = FakeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client)
        #expect(coordinator.isAuthenticated == false)

        let waiter = Task { @MainActor in
            await coordinator.waitForNextSignedInUser()
        }
        // Let the waiter subscribe before the sign-in publishes.
        await Task.yield()
        try await coordinator.signInWithPassword(email: "aziz@manaflow.ai", password: "pw")

        let resolved = await waiter.value
        #expect(resolved == user)
    }

    @Test func resolvesNilWhenTheAwaitingTaskIsCancelled() async throws {
        let client = FakeAuthClient()
        let coordinator = makeCoordinator(client: client)

        let waiter = Task { @MainActor in
            await coordinator.waitForNextSignedInUser()
        }
        await Task.yield()
        waiter.cancel()

        let resolved = await waiter.value
        #expect(resolved == nil)
    }
}
