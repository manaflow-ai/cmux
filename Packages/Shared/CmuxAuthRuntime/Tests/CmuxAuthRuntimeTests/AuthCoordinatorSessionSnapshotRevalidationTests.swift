import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Regression coverage for ``AuthCoordinator/authenticatedSessionSnapshot()``
/// classification while a session revalidation owns the token store.
///
/// Every launch and foreground return kicks a network `/users/me`
/// revalidation, and ``AuthCoordinator/sessionTokenTransitionIsActive`` is true
/// for its whole round trip (up to the sessionRestore timeout). The snapshot
/// used to throw ``AuthError/unauthorized`` for that window, which the iroh
/// broker token source treats as definitively signed out: endpoint activation
/// failed closed with `endpointFailed(authorizationFailed)` on every app
/// launch until the revalidation finished, even though the very same signed-in
/// session produced valid tokens moments later. A transition-owned token store
/// is a transient condition, so the snapshot must classify it
/// ``AuthError/networkError`` (retryable), matching ``AuthCoordinator/accessToken()``'s
/// classification of the same state.
@MainActor
@Suite struct AuthCoordinatorSessionSnapshotRevalidationTests {
    private func makeCoordinator(client: GateableValidationAuthClient) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
    }

    @Test func snapshotDuringRevalidationThrowsTransientNotUnauthorized() async throws {
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

        // The iroh broker token source captures a snapshot mid-revalidation
        // (launch and foreground activations race this window every time).
        // The same session hands back valid tokens the moment the revalidation
        // completes, so the classification must be transient, not signed-out.
        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.authenticatedSessionSnapshot()
        }

        await client.releaseParkedValidation()
        await revalidation.value

        // Once the revalidation settles, the same session serves the pair.
        let snapshot = try await coordinator.authenticatedSessionSnapshot()
        #expect(snapshot.accountID == "u1")
    }
}
