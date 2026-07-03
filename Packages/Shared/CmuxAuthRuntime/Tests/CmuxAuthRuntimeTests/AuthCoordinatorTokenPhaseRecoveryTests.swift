import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Regression coverage for issue #6311: a Stack token phase whose SDK call
/// hangs and ignores cancellation must not gate token acquisition for every
/// session forever. The token-touching gate reopens after a bounded hard window
/// even when the previous phase task never finishes, so reconnects recover
/// without an app restart.
@MainActor
@Suite struct AuthCoordinatorTokenPhaseRecoveryTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    private func makeCoordinator(
        client: any AuthClient,
        clock: ManualTestClock
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        return AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: Self.testTimeouts,
            clock: clock,
            onSignedIn: {}
        )
    }

    @Test func wedgedAccessTokenPhaseRecoversWithoutPreviousTaskFinishing() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingLaunchTokenProbeAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)
        // Reset window elapsed immediately; hard-expiry also zero so the gate
        // must reopen even though the first stuck probe is never released.
        coordinator.tokenTouchingTimedOutResetNanoseconds = 0
        coordinator.tokenTouchingHardExpiryNanoseconds = 0

        // First access-token attempt: the probe starts, hangs ignoring
        // cancellation (modeling a wedged Stack refresh), and times out.
        let first = Task { try await coordinator.accessToken() }
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await first.value }
        #expect(await client.accessStartCount == 1)

        // Second attempt WITHOUT releasing the first probe. The hard-expiry
        // window has elapsed, so the gate must reopen once and start a fresh
        // probe. Before the fix the phase stayed gated on the still-active first
        // task forever, so token acquisition for every session was wedged until
        // the app restarted (#6311).
        let second = Task { try await coordinator.accessToken() }
        let restarted = await waitForAccessStartCount(client, atLeast: 2)
        #expect(restarted)
        if restarted {
            await clock.waitUntilSleepers()
            clock.advance(by: Self.testTimeouts.network)
        }
        await #expect(throws: AuthError.timedOut) { try await second.value }
        #expect(await client.accessStartCount == 2)
        #expect(coordinator.activeTokenTouchingPhases.count == 1)
        #expect(coordinator.abandonedTokenTouchingPhaseIDs.count == 1)

        // A third never-finishing SDK call would grow retained task state
        // without bound. While one abandoned task is still outstanding, the gate
        // fails fast instead of starting another probe.
        let capped = Task { try await coordinator.accessToken() }
        await #expect(throws: AuthError.timedOut) { try await capped.value }
        #expect(await client.accessStartCount == 2)
        #expect(coordinator.activeTokenTouchingPhases.count == 1)
        #expect(coordinator.abandonedTokenTouchingPhaseIDs.count == 1)

        await client.releaseHangingAccessTokenProbe()
        #expect(await waitUntilTokenTouchingCleanupFinished(coordinator))
    }

    private func waitUntilTokenTouchingCleanupFinished(_ coordinator: AuthCoordinator) async -> Bool {
        for _ in 0..<100 {
            if coordinator.activeTokenTouchingPhases.isEmpty,
               coordinator.abandonedTokenTouchingPhaseIDs.isEmpty {
                return true
            }
            await Task.yield()
        }
        return coordinator.activeTokenTouchingPhases.isEmpty
            && coordinator.abandonedTokenTouchingPhaseIDs.isEmpty
    }

    /// Bounded poll for `accessStartCount` so a still-gated phase (the pre-fix
    /// bug) fails the expectation fast instead of hanging the test on the
    /// client's unbounded `waitForAccessStartCount`.
    private func waitForAccessStartCount(
        _ client: HangingLaunchTokenProbeAuthClient,
        atLeast count: Int
    ) async -> Bool {
        for _ in 0..<1000 {
            if await client.accessStartCount >= count {
                return true
            }
            await Task.yield()
        }
        return await client.accessStartCount >= count
    }
}
