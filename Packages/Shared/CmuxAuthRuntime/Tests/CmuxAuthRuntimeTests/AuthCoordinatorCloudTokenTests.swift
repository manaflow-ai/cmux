import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorCloudTokenTests {
    @Test func definitivelyRejectedRefreshIsUnauthorized() async {
        let client = FakeAuthClient(access: "expired", refresh: "rejected")
        await client.setRejectsRefreshOnAccess(true)
        let coordinator = makeCoordinator(client: client)
        await #expect(throws: AuthError.unauthorized) { try await coordinator.currentTokens() }
    }

    @Test func cancelledCloudCallerDoesNotReturnCredentials() async throws {
        let client = FakeAuthClient(access: "access", refresh: "refresh")
        let coordinator = makeCoordinator(client: client)
        let gate = TestPhaseSignal()
        let caller = Task {
            await gate.waitUntilStarted()
            return try await coordinator.currentTokens()
        }
        caller.cancel()
        await gate.markStarted()
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    @Test func cloudCallerCancellationDetachesFromStalledTokenWork() async throws {
        let client = HangingLaunchTokenProbeAuthClient(
            user: CMUXAuthUser(id: "fixture", primaryEmail: nil, displayName: nil)
        )
        let coordinator = makeCoordinator(client: client)
        let caller = Task { try await coordinator.currentTokens() }
        await client.accessTokenDidStart()
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        await client.releaseHangingAccessTokenProbe()
    }

    @Test func cloudCallerDeadlinePreservesRecoverableSession() async throws {
        let client = HangingLaunchTokenProbeAuthClient(
            user: CMUXAuthUser(id: "fixture", primaryEmail: nil, displayName: nil)
        )
        let clock = ManualTestClock()
        let coordinator = makeCoordinator(client: client, timeout: .seconds(2), clock: clock)
        let caller = Task { try await coordinator.currentTokens() }
        await client.accessTokenDidStart()
        await clock.waitUntilSleepers()
        clock.advance(by: .seconds(2))
        await #expect(throws: AuthError.timedOut) { try await caller.value }
        await client.releaseHangingAccessTokenProbe()
        #expect(await client.refreshToken() == "refresh")
    }

    @Test func cloudReaderDoesNotCaptureASignInOwnedTokenStore() async throws {
        let client = GateableValidationAuthClient(user: CMUXAuthUser(id: "fixture", primaryEmail: nil, displayName: nil))
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "fixture@example.invalid", password: "synthetic")
        await client.armCredentialGate()
        let replacement = Task { try await coordinator.signInWithPassword(email: "replacement@example.invalid", password: "synthetic") }
        await client.credentialDidPark()
        await #expect(throws: AuthError.networkError) { try await coordinator.currentTokens() }
        await client.releaseParkedCredential()
        try await replacement.value
    }

    private func makeCoordinator(client: any AuthClient, timeout: Duration = .seconds(1), clock: any Clock<Duration> = ContinuousClock()) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "team"),
            anchor: FakeAnchor(), config: .test, launch: .plain(),
            timeouts: AuthTimeouts(interactiveFlow: .seconds(1), network: timeout), clock: clock
        )
    }
}
