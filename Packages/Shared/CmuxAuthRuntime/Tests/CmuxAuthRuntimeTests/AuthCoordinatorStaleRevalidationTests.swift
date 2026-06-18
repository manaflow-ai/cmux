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

    @Test func staleSignInRollbackDoesNotWipeAnInFlightNewerSignIn() async throws {
        // Like the test above, but the newer sign-in (B) has NOT published
        // yet when the stale task (A) resumes: B is parked between its
        // credential exchange (tokens stored) and its user fetch. A's
        // rollback must not clear the store just because nothing is published
        // yet; the newest sign-in attempt owns the store, and wiping it makes
        // B publish a signed-in shell over empty tokens.
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

        // B starts after sign-out, stores fresh tokens, and parks inside its
        // user fetch (not yet published).
        await client.armValidationGate()
        let newSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.validationDidPark()

        // A resumes first and rolls back; then B's fetch completes.
        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await staleSignIn.value }
        await client.releaseParkedValidation()
        try await newSignIn.value

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(await client.accessToken() != nil)
        #expect(await client.refreshToken() != nil)
    }

    @Test func signOutCancelsAParkedExchangeSoItCannotClobberANewerSignIn() async throws {
        // The rollback gates above stop a stale COMPLETION from clearing the
        // wrong tokens, but nothing stopped the stale EXCHANGE from writing:
        // sign-in A parks in its exchange, the user signs out, sign-in B's
        // exchange writes B's session and parks in its user fetch, then A's
        // exchange resumes and overwrites the store with A's session. The
        // high-water gate correctly skips A's rollback (B wrote after A
        // began), so the store ends up holding A's tokens while B publishes
        // B's user: the UI says B but the device authenticates as the session
        // the user signed out of mid-flight. Sign-out must cancel the parked
        // exchange so the SDK's write chokepoint (`publishSessionTokens`
        // checks cancellation before storing) refuses the late write.
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

        // B's exchange completes (the store's first write: "access-1") and
        // parks inside its user fetch, not yet published.
        await client.armValidationGate()
        let newSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.validationDidPark()

        // A's exchange resumes LAST, after B's write. Cancelled by the
        // sign-out, it must surface the cancellation without storing.
        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await staleSignIn.value }

        await client.releaseParkedValidation()
        try await newSignIn.value

        // B's published session and B's stored tokens must agree: the store
        // still holds the session B's exchange minted, not a later write
        // from the cancelled stale exchange.
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(await client.accessToken() == "access-1")
        #expect(await client.refreshToken() == "refresh-1")
    }

    @Test func failedNewerAttemptDoesNotBlockStaleRollback() async throws {
        // Counterpart to the in-flight test above: sign-in B starts after the
        // sign-out but fails fast (offline) BEFORE its exchange writes
        // anything. B bumped the attempt counter, but it never took ownership
        // of the token store, so when stale A resumes and re-stores its old
        // tokens the rollback must still clear them; otherwise the signed-out
        // device keeps credentials the next launch restore resurrects.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let store = FakeKeyValueStore()
        let online = OnlineFlag()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            isOnline: { await online.value }
        )

        await client.armCredentialGate()
        let staleSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()

        await coordinator.signOut()
        #expect(coordinator.isAuthenticated == false)

        // B fails its connectivity probe after registering as an attempt.
        await online.set(false)
        await #expect(throws: AuthError.offline) {
            try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        }

        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await staleSignIn.value }

        #expect(coordinator.isAuthenticated == false)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
    }
}

/// Mutable connectivity flag for scripting `isOnline` mid-test.
private actor OnlineFlag {
    private(set) var value = true
    func set(_ newValue: Bool) { value = newValue }
}

/// Counts `onSignedIn` hook runs across actor hops.
private actor SignedInHookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
