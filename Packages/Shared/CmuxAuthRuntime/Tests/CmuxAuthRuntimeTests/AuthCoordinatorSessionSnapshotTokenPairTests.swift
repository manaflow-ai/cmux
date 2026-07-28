import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Regression coverage for ``AuthCoordinator/authenticatedSessionSnapshot()``
/// reading the access and refresh tokens as ONE coherent pair.
///
/// The snapshot feeds the iroh broker's `Authorization: Bearer <access>` +
/// `X-Stack-Refresh-Token: <refresh>` header pair. Reading the access token and
/// refresh token through two separate awaits let a concurrent
/// `forceRefreshAccessToken()` rotate the credentials between them, so the
/// snapshot could pair an OLD access token with a freshly rotated refresh token.
/// Neither the pinned `sessionGeneration` nor `sessionTokenTransitionIsActive`
/// trips on a plain token rotation, so both snapshot guards pass and the torn
/// pair reaches the server, which rejects it.
///
/// The fix derives the access token FROM the one captured refresh token, so the
/// returned access always belongs to the returned refresh.
@MainActor
@Suite struct AuthCoordinatorSessionSnapshotTokenPairTests {
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

    /// The store holds a STALE access token alongside a rotated refresh token,
    /// exactly as it would the instant after a concurrent force refresh replaced
    /// the refresh token but before the separately-read access caught up. The
    /// snapshot must not return that stale access; it must return the access
    /// minted for the captured refresh token.
    @Test func snapshotDerivesAccessFromCapturedRefreshTokenNotStaleStoredAccess() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        // `accessToken()` returns the stale token; `refreshToken()` the rotated
        // one — the torn pair the legacy two-await read would hand back.
        let client = FakeAuthClient(access: "access-old", refresh: "refresh-new", user: user)
        // A mint from the captured refresh yields the coherent access token.
        await client.setMintedAccessToken("access-new")
        let coordinator = makeCoordinator(client: client)
        coordinator.start()

        let snapshot = try await coordinator.authenticatedSessionSnapshot()

        // The access token must be the one minted for the captured refresh, never
        // the separately-read stale "access-old".
        #expect(snapshot.accessToken == "access-new")
        #expect(snapshot.refreshToken == "refresh-new")
        // Prove the access token was derived from the captured refresh token.
        #expect(await client.lastMintedRefreshToken == "refresh-new")
    }
}
