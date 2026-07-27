import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorTokenTouchingPhaseCancellationTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock
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
            clock: clock
        )
    }

    @Test func cancelledAccessTokenCallDoesNotStartSecondStuckTokenPhase() async {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        let first = Task { try await coordinator.accessToken() }
        await client.accessTokenDidStart()
        first.cancel()
        await waitUntilTokenTouchingPhaseGated(coordinator, phase: .accessToken)

        let second = Task { try await coordinator.accessToken() }
        await #expect(throws: AuthError.timedOut) { try await second.value }
        #expect(await client.accessStartCount == 1)

        await client.releaseHangingAccessTokenProbe()
        await #expect(throws: CancellationError.self) { try await first.value }
        await waitUntilTokenTouchingCleanupFinished(coordinator)
    }

    private func waitUntilTokenTouchingPhaseGated(_ coordinator: AuthCoordinator, phase: AuthPhase) async {
        for _ in 0..<100 {
            if coordinator.timedOutTokenTouchingPhaseStates[phase] != nil {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilTokenTouchingCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeTokenTouchingPhases.isEmpty {
                return
            }
            await Task.yield()
        }
    }
}
