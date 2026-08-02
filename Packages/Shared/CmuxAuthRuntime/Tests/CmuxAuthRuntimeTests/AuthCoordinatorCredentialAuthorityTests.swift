import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The credential authority: ``AuthCoordinator`` is the only component that
/// may mint, and every rejection-driven recovery coalesces onto one in-flight
/// mint.
///
/// Stack rotates the refresh token on every mint, so independent lanes (RPC
/// retry, iroh broker recovery) minting past each other invalidate each
/// other's in-flight credential pairs — the wake-time 401 storm from the
/// 2026-07-31 field rings. Single-flighting the mint and recovering via
/// ``AuthCoordinator/credentialsAfterRejection(accountID:rejectedRefreshToken:)``
/// makes rotation happen at most once per genuine rejection, and a rejection
/// whose pair already rotated recovers with zero mints.
@MainActor
@Suite struct AuthCoordinatorCredentialAuthorityTests {
    private func makeCoordinator(client: FakeAuthClient) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            clock: ContinuousClock(),
            isOnline: { true }
        )
    }

    /// Two concurrent rejections of the same pair produce exactly one mint;
    /// both callers receive the rotated pair.
    @Test func concurrentRejectionsCoalesceOntoOneMint() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()
        // Prove the session is live before scripting the rejection.
        _ = try await coordinator.authenticatedSessionSnapshot()

        await client.armForceRefreshGate()
        async let first = coordinator.credentialsAfterRejection(
            accountID: "u1",
            rejectedRefreshToken: "refresh-1"
        )
        await client.waitForParkedForceRefresh()
        async let second = coordinator.credentialsAfterRejection(
            accountID: "u1",
            rejectedRefreshToken: "refresh-1"
        )
        // The mint rotates the pair, exactly like the live SDK.
        await client.setTokens(access: "access-2", refresh: "refresh-2")
        await client.setForceRefreshResult("access-2")
        await client.releaseForceRefreshGate()

        let recoveredFirst = try await first
        let recoveredSecond = try await second
        #expect(recoveredFirst.refreshToken == "refresh-2")
        #expect(recoveredSecond.refreshToken == "refresh-2")
        #expect(await client.forceRefreshCount == 1)
    }

    /// A rejection whose pair already rotated (another lane minted between
    /// capture and validation) recovers from the store alone: zero mints.
    @Test func rejectionOfAlreadyRotatedPairRecoversWithoutMinting() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-2", refresh: "refresh-2", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()

        let recovered = try await coordinator.credentialsAfterRejection(
            accountID: "u1",
            rejectedRefreshToken: "refresh-1"
        )

        #expect(recovered.refreshToken == "refresh-2")
        #expect(recovered.accessToken == "access-2")
        #expect(await client.forceRefreshCount == 0)
    }

    /// Direct ``forceRefreshAccessToken()`` callers (the RPC lane) coalesce
    /// with each other and with rejection recoveries on the same in-flight
    /// mint.
    @Test func concurrentForceRefreshCallsCoalesce() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()
        _ = try await coordinator.authenticatedSessionSnapshot()

        await client.armForceRefreshGate()
        async let first = coordinator.forceRefreshAccessToken()
        await client.waitForParkedForceRefresh()
        async let second = coordinator.forceRefreshAccessToken()
        await client.setForceRefreshResult("access-2")
        await client.releaseForceRefreshGate()

        let firstToken = try await first
        let secondToken = try await second
        #expect(firstToken == "access-2")
        #expect(secondToken == "access-2")
        #expect(await client.forceRefreshCount == 1)
    }

    /// Recovery is account-fenced: a session that changed accounts between the
    /// rejection and the recovery fails closed instead of handing account B's
    /// credentials to account A's request.
    @Test func recoveryForDifferentAccountFailsClosed() async throws {
        let user = CMUXAuthUser(id: "u2", primaryEmail: "b@b.com", displayName: "B")
        let client = FakeAuthClient(access: "access-2", refresh: "refresh-2", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()

        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.credentialsAfterRejection(
                accountID: "u1",
                rejectedRefreshToken: "refresh-2"
            )
        }
    }
}
