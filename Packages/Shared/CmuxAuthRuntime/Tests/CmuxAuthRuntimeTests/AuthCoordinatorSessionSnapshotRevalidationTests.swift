import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Regression coverage for ``AuthCoordinator/authenticatedSessionSnapshot()``
/// while a launch restore or foreground revalidation owns the token store.
///
/// Every launch and foreground return kicks a network `/users/me`
/// revalidation, and ``AuthCoordinator/sessionTokenTransitionIsActive`` is true
/// for its whole round trip (up to the sessionRestore timeout). The snapshot
/// used to queue behind that round trip (and before that, to throw
/// ``AuthError/unauthorized`` for the window), so endpoint activation stalled
/// or failed closed on every app launch even though the tokens it needed were
/// sitting in the keychain the whole time. A complete stored pair must be
/// served immediately from local storage; only a store with no usable pair
/// classifies the transition window as transient
/// (``AuthError/networkError``, retryable) rather than signed out.
@MainActor
@Suite struct AuthCoordinatorSessionSnapshotRevalidationTests {
    private func makeCoordinator(
        client: GateableValidationAuthClient,
        store: FakeKeyValueStore = FakeKeyValueStore()
    ) -> AuthCoordinator {
        AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
    }

    @Test func snapshotDuringRevalidationServesStoredPairImmediately() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        // A foreground revalidation parks inside its /users/me round trip; the
        // token store is transition-owned for the whole window.
        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()

        // A backend token source captures a snapshot mid-revalidation
        // (launch and foreground activations race this window every time).
        // The pair is already persisted, so the snapshot must be served from
        // the keychain immediately instead of queueing behind the network.
        let snapshot = try await coordinator.authenticatedSessionSnapshot()
        #expect(snapshot.accountID == "u1")
        #expect(snapshot.accessToken == "access-1")
        #expect(snapshot.refreshToken == "refresh-1")

        await client.releaseParkedValidation()
        await revalidation.value
    }

    @Test func snapshotDuringLaunchRestoreServesStoredPairBeforeBootstrapCompletes() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        // A previous run's session survives: cached identity, has-tokens
        // marker, and the keychain pair are all present before this process's
        // restore probe has exchanged a single packet.
        await client.seedTokens(access: "stored-access", refresh: "stored-refresh")
        let store = FakeKeyValueStore()
        try CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user").save(user)
        CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens").setHasTokens(true)
        let coordinator = makeCoordinator(client: client, store: store)

        // Launch restore parks inside its /users/me round trip.
        await client.armValidationGate()
        coordinator.start()
        await client.validationDidPark()

        // The connection layer asks for credentials while the restore is still
        // in flight: the stored pair must come back without awaiting bootstrap.
        let snapshot = try await coordinator.authenticatedSessionSnapshot()
        #expect(snapshot.accountID == "u1")
        #expect(snapshot.accessToken == "stored-access")
        #expect(snapshot.refreshToken == "stored-refresh")

        await client.releaseParkedValidation()
        await coordinator.awaitBootstrapped()
    }

    @Test func snapshotWithEmptyStoreDuringRevalidationStaysTransient() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        await client.armValidationGate()
        let revalidation = Task { await coordinator.revalidateSession() }
        await client.validationDidPark()
        // The store empties mid-transition (a refresh rotation in flight, or
        // the SDK dropped the pair): with nothing stored to serve, the
        // transition-owned window must classify as transient, not signed-out.
        await client.clearLocalSession()

        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.authenticatedSessionSnapshot()
        }

        await client.releaseParkedValidation()
        await revalidation.value
    }

    @Test func snapshotDuringSignInExchangeDoesNotServeStoredPair() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        // A second sign-in exchange owns the store: a mid-exchange read could
        // pair the published identity with the wrong session's tokens, so the
        // fast path must decline and the read stays retryable until the
        // exchange reaches its terminal state.
        await client.armCredentialGate()
        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()

        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.authenticatedSessionSnapshot()
        }

        await client.releaseParkedCredential()
        _ = try? await signIn.value
    }
}
