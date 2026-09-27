import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorCancellationTests {
    private func makeCoordinator(client: any AuthClient) -> AuthCoordinator {
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

    @Test func taskCancellationMapsToCancelledNotGenericError() {
        // Backing out of a stuck sign-in is not a failure: it must map to
        // .cancelled (which the UI silently ignores), not the generic
        // "Something went wrong" server error.
        #expect(AuthError(displaySafe: CancellationError()) == .cancelled)
    }

    @Test func cancellingInFlightOAuthSignInThrowsCancelledAndStopsLoading() async {
        let client = HangingOAuthAuthClient()
        let coordinator = makeCoordinator(client: client)

        let signIn = Task { try await coordinator.signInWithApple() }
        await client.oauthDidStart()
        signIn.cancel()

        await #expect(throws: AuthError.cancelled) { try await signIn.value }
        #expect(coordinator.isLoading == false)
    }
}
