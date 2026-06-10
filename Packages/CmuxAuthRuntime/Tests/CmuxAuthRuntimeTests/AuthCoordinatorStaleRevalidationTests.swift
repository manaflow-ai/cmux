import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Local-first sign-out clears local state up front and no longer ends with a
/// final `clearAuthState()`, so auth work that was already in flight when the
/// user signed out must not republish the cleared session when it resumes.
/// The validation fetch departed with valid tokens before sign-out destroyed
/// them, so it resumes with a signed-in user; without a session-generation
/// guard the coordinator flips back to `isAuthenticated == true` over an empty
/// token store, a stale shell that fails at connect time.
@MainActor
@Suite struct AuthCoordinatorStaleRevalidationTests {
    @Test func staleRevalidationCannotResurrectSignedOutSession() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        // A foreground revalidation parks inside its /users/me round trip.
        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()

        // Local-first sign-out completes while that validation is in flight.
        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)

        // The stale fetch resumes with a signed-in user. It must be dropped,
        // not republished over the signed-out session.
        await client.releaseParkedValidation()
        await revalidation.value

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    @Test func staleTeamRefreshAndSignedInHookAreDroppedAfterSignOut() async throws {
        // The publish path keeps running after the signed-in flags are set:
        // it awaits the team refresh and then the onSignedIn hook (push token
        // re-upload in production). A sign-out landing during the team fetch
        // must drop the trailing writes AND the hook, or the signed-out shell
        // gets the old account's teams persisted and the push token
        // re-registered for an account the user just left.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let team = CMUXAuthTeam(id: "t1", displayName: "Team One", slug: nil)
        let client = GateableValidationAuthClient(user: user, teams: [team])
        let store = FakeKeyValueStore()
        let hookRuns = SignedInHookCounter()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            onSignedIn: { await hookRuns.increment() }
        )
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)
        #expect(await hookRuns.value == 1)

        // A revalidation parks inside the team refresh, after the signed-in
        // flags were re-published but before teams and the hook.
        await client.armTeamsGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.teamsDidPark()

        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)

        await client.releaseParkedTeams()
        await revalidation.value

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.availableTeams.isEmpty)
        #expect(coordinator.selectedTeamID == nil)
        #expect(await hookRuns.value == 1)
    }
}

/// Counts `onSignedIn` hook runs across actor hops.
private actor SignedInHookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
