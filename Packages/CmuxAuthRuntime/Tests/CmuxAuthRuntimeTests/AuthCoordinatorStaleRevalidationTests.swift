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
}
