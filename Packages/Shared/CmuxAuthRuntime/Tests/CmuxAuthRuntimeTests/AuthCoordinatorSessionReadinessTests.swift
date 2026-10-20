import CMUXAuthCore
import Foundation
import Observation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorSessionReadinessTests {
    /// The hosted browser sign-in (``AuthCoordinator/completeExternalSignIn()``)
    /// sets `isAuthenticated` before its team refresh and post-sign-in hook
    /// end, and `currentTokens()` refuses until then. On the 2026-10-20
    /// nightly, Cloud's install registration and machine list ran in that
    /// window and failed. A session that reads ready must serve tokens, and
    /// readiness must change (observably) when the sign-in ends.
    @Test func externalSignInIsReadyOnlyOnceTokensAreServed() async throws {
        let hookStarted = TestPhaseSignal()
        let hookBlocker = TestContinuationBlocker()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let coordinator = makeCoordinator(client: FakeAuthClient(access: "access", refresh: "refresh", user: user)) {
            await hookStarted.markStarted()
            await hookBlocker.wait()
        }

        let signIn = Task { try await coordinator.completeExternalSignIn() }
        await hookStarted.waitUntilStarted()
        #expect(coordinator.isAuthenticated)
        let changed = TestPhaseSignal()
        let whileCompleting = withObservationTracking {
            coordinator.sessionReadiness
        } onChange: {
            Task { await changed.markStarted() }
        }
        let servedWhileCompleting = (try? await coordinator.currentTokens()) != nil
        await hookBlocker.release()
        try await signIn.value

        #expect(!servedWhileCompleting)
        try #require(whileCompleting == .completing, "a session whose tokens are refused must not read ready")
        await changed.waitUntilStarted()
        #expect(coordinator.sessionReadiness == .ready(accountID: "u1"))
        #expect(try await coordinator.currentTokens().accessToken == "access")
    }

    @Test func signedOutReadsSignedOut() {
        let coordinator = makeCoordinator(client: FakeAuthClient()) {}
        #expect(coordinator.sessionReadiness == .signedOut)
    }

    private func makeCoordinator(client: any AuthClient, onSignedIn: @escaping @Sendable () async -> Void) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            // The manual clock never advances: no deadline ends the parked hook.
            clock: ManualTestClock(),
            onSignedIn: onSignedIn
        )
    }
}
