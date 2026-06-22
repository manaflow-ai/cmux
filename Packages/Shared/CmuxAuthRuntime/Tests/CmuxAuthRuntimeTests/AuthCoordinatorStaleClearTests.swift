import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Stale validation clears and stale-attempt cancellation must never damage a
/// FRESH sign-in: a parked clear, validation failure, or auto-login
/// cancellation that belongs to an older session generation cannot wipe or
/// unpublish the tokens of a newer session, cancel an in-flight newer sign-in,
/// or skip the rollback path when it resumes inside sign-out.
@MainActor
@Suite struct AuthCoordinatorStaleClearTests {
    @Test func staleValidationFailureDoesNotClearAFreshSignIn() async throws {
        // A revalidation of the OLD cached session parks in its fetch; the
        // user completes a fresh sign-in meanwhile (no sign-out, so nothing
        // bumped the clear count); then the old validation fails with a
        // definitive rejection. That failure is about the old session: it
        // must not clear the freshly published one. Publishing a session must
        // advance the epoch just like clearing does.
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

        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()

        // The old validation resumes with a definitive rejection.
        await client.setGatedValidationError(AuthError.unauthorized)
        await client.releaseParkedValidation()
        await revalidation.value

        // Fresh sign-in preflight now waits for stale validation work to
        // quiesce before it writes a newer session.
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(await client.accessToken() != nil)
        #expect(await client.refreshToken() != nil)
    }

    @Test func staleValidationClearDoesNotUnpublishAFreshSignIn() async throws {
        // Variant of the test above where the fresh sign-in completes while
        // the stale validation is already INSIDE its awaited token-store
        // clear. The stale flow's trailing clearAuthState() must re-check the
        // epoch after that suspension instead of unconditionally unpublishing
        // the session that just landed.
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

        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()

        // The old validation fails definitively and suspends inside the
        // token-store clear of its .clearSession handling.
        await client.setGatedValidationError(AuthError.unauthorized)
        await client.armClearGate()
        await client.releaseParkedValidation()
        await client.clearDidPark()

        await client.releaseParkedClear()
        await revalidation.value

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
    }

    @Test func parkedStaleClearCannotWipeAFreshSignInsTokens() async throws {
        // Same interleave as the test above, but asserting the TOKENS. The
        // stale flow's write-high-water check runs before its clear suspends,
        // so a fresh sign-in that writes the store while the clear is parked
        // is invisible to it; an unconditional clear then wipes the fresh
        // session's tokens while its published state survives: an
        // authenticated shell with empty credentials that fails at the next
        // API call or launch restore. The clear must be a compare-and-clear
        // against the stale session's refresh token, atomic at the token
        // store, so a store that changed owners after the decision is left
        // alone.
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

        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()

        // The old validation fails definitively and suspends inside the
        // token-store clear of its .clearSession handling.
        await client.setGatedValidationError(AuthError.unauthorized)
        await client.armClearGate()
        await client.releaseParkedValidation()
        await client.clearDidPark()

        await client.releaseParkedClear()
        await revalidation.value

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        // The fresh session keeps BOTH its published state and its tokens.
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(await client.accessToken() == "access-2")
        #expect(await client.refreshToken() == "refresh-2")
    }

    @Test func exchangeResumingInsideSignOutTakesTheRollbackPath() async throws {
        // Sign-out must already have won by the time it first suspends: an
        // in-flight credential exchange that resumes while sign-out is parked
        // inside the token-store clear (one in-flight sign-in plus sign-out,
        // no second attempt needed) must not complete as a live sign-in.
        // Before sign-out cancelled in-flight exchanges up front, the resumed
        // exchange saw the pre-sign-out epoch (sign-out bumps it only after
        // the clear), passed its completion guard, and left freshly written
        // tokens behind for the next launch restore to resurrect.
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

        // Sign-out runs its token-store clear, then suspends right after it,
        // before any of its post-clear MainActor code.
        await client.armClearGate()
        let signOut = Task { await coordinator.signOut() }
        await client.clearDidPark()

        // The parked exchange resumes NOW: it writes fresh tokens after the
        // store clear and completes while sign-out is still suspended. It
        // must already see the sign-out epoch and take the rollback path.
        await client.releaseParkedCredential()
        await #expect(throws: AuthError.cancelled) { try await signIn.value }

        await client.releaseParkedClear()
        await signOut.value

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(await client.accessToken() == nil)
        #expect(await client.refreshToken() == nil)
    }

    @Test func staleValidationClearMustNotCancelAnInFlightSignIn() async throws {
        // An old revalidation parks in its fetch; the user starts a fresh
        // sign-in whose exchange has written tokens (new store owner) but
        // whose user fetch is still in flight; then the old validation fails
        // definitively. Its cleanup correctly skips the token store (the
        // high-water gate) but must skip the published-state clear too: that
        // clear bumps the epoch, which spuriously cancels the in-flight
        // sign-in and leaves its freshly written tokens orphaned behind a
        // signed-out UI for the next launch restore to resurrect. Once a
        // newer exchange owns the store, the stale flow must do nothing.
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

        // The old revalidation parks first and will fail once released.
        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()
        await client.setGatedValidationError(AuthError.unauthorized)

        // Fresh sign-in preflight now waits for the old validation to finish
        // before starting its exchange.
        await client.releaseParkedValidation()
        await revalidation.value

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(await client.accessToken() != nil)
        #expect(await client.refreshToken() != nil)
    }

    @Test func staleAutoLoginCancellationDoesNotWipeANewerSession() async throws {
        // A launch/dev auto-login is a sign-in flow like any other: sign-out
        // cancels its parked credential exchange. But the auto-login wraps
        // the flow in its own failure handler, and treating that cancellation
        // as a generic failure runs the handler's clear. When the user has
        // already completed a fresh manual sign-in by the time the stale
        // auto-login resumes, that clear wipes the NEWER session: published
        // state, caches, and the fresh tokens. A cancelled auto-login means a
        // competing session transition won; it must touch nothing.
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
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_STACK_EMAIL": "auto@b.com",
                    "CMUX_UITEST_STACK_PASSWORD": "pw",
                ],
                includesDevAuth: false
            )
        )

        // The auto-login parks inside its credential exchange.
        await client.armCredentialGate()
        let restore = Task { await coordinator.revalidateSession() }
        await client.credentialDidPark()

        // The user signs out, cancelling the parked exchange. Fresh manual
        // sign-in preflight waits for the stale auto-login to quiesce before
        // writing newer tokens.
        await coordinator.signOut()

        // The stale auto-login resumes and fails with the cancellation.
        await client.releaseParkedCredential()
        await restore.value

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        // The fresh session survives intact.
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(await client.accessToken() != nil)
        #expect(await client.refreshToken() != nil)
    }
}
