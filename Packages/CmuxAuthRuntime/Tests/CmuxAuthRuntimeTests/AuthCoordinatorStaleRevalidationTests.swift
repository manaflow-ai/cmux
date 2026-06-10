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

    @Test func signOutDuringCredentialExchangeWins() async throws {
        // The credential exchange itself is a network await that stores fresh
        // tokens when it resumes. A sign-out landing while the exchange is in
        // flight clears an empty-or-old store and bumps the generation, but
        // the resuming exchange then RE-stores tokens sign-out never saw and
        // the completion publishes the session: sign-out silently undone. The
        // sign-in flow must capture the generation before the exchange, drop
        // the completion, and clear the just-stored tokens (surfacing the
        // race as a cancellation, which the sign-in UI treats as a deliberate
        // back-out).
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

        await client.armCredentialGate()
        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()

        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)

        // The exchange resumes, stores fresh tokens, and the flow completes.
        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await signIn.value }

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        // The tokens the resuming exchange stored must not outlive sign-out,
        // or the next launch restore resurrects the signed-out session.
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
    }

    @Test func staleSignInRollbackDoesNotWipeANewerSession() async throws {
        // Worst-case interleave of the rollback above: sign-in A parks in its
        // exchange, the user signs out, then completes a SECOND sign-in (B)
        // before A resumes. A's stale completion must not roll the token
        // store back: that would wipe B's tokens while B's published state
        // still says signed in (a stale shell that fails at connect time).
        // The rollback may only run while no newer session has been
        // published.
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

        await client.armCredentialGate()
        let staleSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()

        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)

        // The user signs in again before the stale task resumes.
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await staleSignIn.value }

        // The newer session survives the stale completion intact.
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(await client.accessToken() != nil)
        #expect(await client.refreshToken() != nil)
    }
}

/// Counts `onSignedIn` hook runs across actor hops.
private actor SignedInHookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
