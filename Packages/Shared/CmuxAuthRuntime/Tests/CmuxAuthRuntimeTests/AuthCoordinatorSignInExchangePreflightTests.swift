import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorSignInExchangePreflightTests {
    private static let testTimeouts = AuthTimeouts(
        interactiveFlow: .seconds(5),
        network: .seconds(2)
    )

    @Test func timedOutCredentialExchangeBlocksDifferentSignInMethod() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = GateableValidationAuthClient(user: user)
        let coordinator = makeCoordinator(client: client, clock: clock)

        try await coordinator.sendCode(to: "a@b.com")
        await client.armCredentialGate()
        let passwordSignIn = Task { try await coordinator.signInWithPassword(email: "a@b.com", password: "pw") }
        await client.credentialDidPark()
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await passwordSignIn.value }

        let magicSignIn = Task { try await coordinator.verifyCode("code") }
        await clock.waitUntilSleepers()
        clock.advance(by: Self.testTimeouts.network)
        await #expect(throws: AuthError.timedOut) { try await magicSignIn.value }
        #expect(await client.credentialStartCount == 1)
        #expect(await client.magicLinkStartCount == 0)

        await client.releaseParkedCredential()
        await waitUntilSignInExchangeCleanupFinished(coordinator)
    }

    private func makeCoordinator(client: any AuthClient, clock: ManualTestClock) -> AuthCoordinator {
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

    private func waitUntilSignInExchangeCleanupFinished(_ coordinator: AuthCoordinator) async {
        for _ in 0..<100 {
            if coordinator.activeSignInExchanges.isEmpty {
                return
            }
            await Task.yield()
        }
    }
}
