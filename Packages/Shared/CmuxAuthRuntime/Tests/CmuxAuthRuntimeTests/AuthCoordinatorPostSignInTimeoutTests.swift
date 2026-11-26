import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorPostSignInTimeoutTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    @Test func timedOutPostSignInHookRemainsTrackedThroughSignOut() async throws {
        let clock = ManualTestClock()
        let hookStarted = TestPhaseSignal()
        let hookBlocker = TestContinuationBlocker()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock) {
            await hookStarted.markStarted()
            await hookBlocker.wait()
        }

        let signIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await hookStarted.waitUntilStarted()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)

        try await signIn.value
        #expect(coordinator.activePostSignInHooks.count == 1)

        let signOut = Task { await coordinator.signOut(teardownTimeout: Self.testTimeouts.network) }
        await clock.waitUntilSleepers()
        #expect(coordinator.isAuthenticated == false)
        clock.advance(by: Self.testTimeouts.network)
        await signOut.value

        #expect(coordinator.activePostSignInHooks.count == 1)
        #expect(coordinator.isAuthenticated == false)
        await hookBlocker.release()
        await waitUntilPostSignInHookCleanupFinished(coordinator)
        #expect(coordinator.activePostSignInHooks.isEmpty)
    }

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock,
        onSignedIn: @escaping @Sendable () async -> Void
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: Self.testTimeouts,
            clock: clock,
            onSignedIn: onSignedIn
        )
    }

    private func waitUntilPostSignInHookCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activePostSignInHooks.isEmpty {
                return
            }
            await Task.yield()
        }
    }
}
