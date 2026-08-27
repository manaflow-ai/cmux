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

    /// The store holds a STALE (no-longer-valid) access token alongside a
    /// rotated refresh token, exactly as it would the instant after a
    /// concurrent force refresh replaced the refresh token but before the
    /// separately-read access caught up. The snapshot must not return that
    /// stale access; it must return the access resolved for the captured
    /// refresh token.
    @Test func snapshotDerivesAccessFromCapturedRefreshTokenNotStaleStoredAccess() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        // The store holds the stale token beside the rotated refresh — the torn
        // pair the legacy two-await read would hand back. The stale token is no
        // longer fresh, so the live-store resolution must refresh it.
        let client = FakeAuthClient(access: "access-old", refresh: "refresh-new", user: user)
        await client.setStoredAccessTokenStale(true)
        // The refresh yields the coherent access token.
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

    /// A VALID stored access token is reused as-is: the coherent pair read must
    /// not require the network when the store already holds a usable pair.
    /// Forcing a mint on every capture made the snapshot (and with it broker
    /// activation) fail during an offline launch or a Stack outage even though
    /// valid credentials were sitting in the store.
    @Test func snapshotReusesValidStoredAccessTokenWithoutMinting() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        // The stored access is still fresh — the live store reuses it offline.
        let client = FakeAuthClient(access: "access-ok", refresh: "refresh-1", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()

        let snapshot = try await coordinator.authenticatedSessionSnapshot()

        #expect(snapshot.accessToken == "access-ok")
        #expect(snapshot.refreshToken == "refresh-1")
        // No network mint happened: the valid stored pair was reused.
        #expect(await client.mintedAccessTokenCount == 0)
    }

    /// A refreshed access token must be PERSISTED, so repeated captures reuse
    /// it instead of re-minting per request. Resolving the pair through an
    /// ephemeral side store refreshed over the network on every capture once
    /// the stored token aged past its freshness window — the long-lived broker
    /// source captures per request, so that meant a Stack round-trip (and
    /// throttling exposure) on every discovery and relay-policy call.
    @Test func repeatedCapturesReuseThePersistedRefreshedAccessToken() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-old", refresh: "refresh-1", user: user)
        await client.setStoredAccessTokenStale(true)
        await client.setMintedAccessToken("access-new")
        let coordinator = makeCoordinator(client: client)
        coordinator.start()

        let first = try await coordinator.coherentTokenPair()
        let second = try await coordinator.coherentTokenPair()

        #expect(first.accessToken == "access-new")
        #expect(second.accessToken == "access-new")
        // ONE refresh, persisted into the live store; the second capture reused it.
        #expect(await client.mintedAccessTokenCount == 1)
    }

    /// An ordinary same-account revalidation (every foreground return) must NOT
    /// advance the session generation: long-lived operations pin their broker
    /// credentials to it (the forget flow, the activation runtime's source),
    /// and a bump on every foreground would permanently starve those pins even
    /// though the very same session remains signed in. Genuine transitions
    /// (sign-out, sign-in) still advance it.
    @Test func sameAccountRevalidationKeepsTheSessionGeneration() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()
        _ = try await coordinator.authenticatedSessionSnapshot()
        let pinned = coordinator.authSessionGeneration

        // The ordinary foreground path: same account, still signed in.
        await coordinator.revalidateSession()

        #expect(coordinator.authSessionGeneration == pinned)

        // A genuine transition still advances the epoch.
        await coordinator.signOut()
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.authSessionGeneration != pinned)
    }

    /// A COMPLETED sign-in is a session replacement even for the same account:
    /// the credential exchange minted a fresh token session, so every
    /// operation pinned to the previous generation (the forget flow's frozen
    /// credential pair, the activation runtime's pinned source) must fail
    /// closed rather than keep acting with the replaced session's authority.
    /// Only same-account REVALIDATION (no new exchange) preserves the
    /// generation.
    @Test func sameAccountSignInAdvancesTheSessionGeneration() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: user)
        let coordinator = makeCoordinator(client: client)
        coordinator.start()
        _ = try await coordinator.authenticatedSessionSnapshot()
        let pinned = coordinator.authSessionGeneration

        // A fresh credential exchange for the SAME account, while still
        // signed in (e.g. the user re-enters their password).
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.authSessionGeneration != pinned)
    }
}
