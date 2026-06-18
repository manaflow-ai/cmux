import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

/// Behavior tests for the live-session-validity seam that drives the mobile
/// login-vs-main gate.
///
/// The mobile root scene routes to the sign-in page whenever
/// ``AuthCoordinator/isAuthenticated`` is `false`, so these tests assert that the
/// coordinator flips that latch on a definitively-gone session (login) and only
/// on a definitively-gone session (never on a recoverable transient failure that
/// would sign out a valid user).
@MainActor
@Suite struct AuthCoordinatorSessionValidityTests {
    private func makeCoordinator(
        client: FakeAuthClient,
        launch: AuthLaunchOptions = .plain(),
        isOnline: @escaping @Sendable () async -> Bool = { true }
    ) -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: launch,
            isOnline: isOnline
        )
        return (coordinator, store)
    }

    private func signedInCoordinator(
        client: FakeAuthClient
    ) async throws -> (AuthCoordinator, FakeKeyValueStore) {
        let (coordinator, store) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)
        return (coordinator, store)
    }

    // (a) An invalid/empty session leaves the login gate showing login: no
    // access token, no refresh token -> revalidation routes to login.
    @Test func emptySessionRevalidatesToLogin() async {
        let (coordinator, store) = makeCoordinator(
            client: FakeAuthClient(access: nil, refresh: nil)
        )
        await coordinator.revalidateSession()
        // The root scene shows the sign-in page whenever `isAuthenticated` is
        // false, so this is the login-routing assertion.
        #expect(coordinator.isAuthenticated == false)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    // (b) A transient failure (access token unmintable but refresh token still
    // present) stays retryable and does NOT clear the session or route to login.
    @Test func transientFailurePreservesSessionAndStaysRetryable() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        // Access token gone, refresh token survives (the SDK preserves it across
        // a network/server hiccup).
        await client.setTokens(access: nil, refresh: "refresh")

        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.accessToken()
        }
        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens") == true)
    }

    @Test func forceRefreshTransientFailurePreservesSession() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        // Force-refresh yields no new token, but the refresh token survives.
        await client.setForceRefreshResult(nil)
        await client.setTokens(access: nil, refresh: "refresh")

        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.forceRefreshAccessToken()
        }
        #expect(coordinator.isAuthenticated == true)
        #expect(store.bool(forKey: "has_tokens") == true)
    }

    // (c) A definitive failure (no access token AND no refresh token; the SDK
    // definitively rejected and cleared the session) self-clears and routes to
    // login from both definitive accessors.
    @Test func definitiveFailureOnAccessTokenRoutesToLogin() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        await client.setTokens(access: nil, refresh: nil)

        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.accessToken()
        }
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    @Test func definitiveFailureOnForceRefreshRoutesToLogin() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        await client.setForceRefreshResult(nil)
        await client.setTokens(access: nil, refresh: nil)

        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.forceRefreshAccessToken()
        }
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    // A session that dies while backgrounded routes to login on the next
    // foreground re-validation (the live-store probe finds no usable token).
    @Test func foregroundRevalidationRoutesDeadSessionToLogin() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        // Both tokens gone (definitively rejected while backgrounded).
        await client.setTokens(access: nil, refresh: nil)

        await coordinator.revalidateSession()

        #expect(coordinator.isAuthenticated == false)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    // The discriminator pair: validating a cached session throws the SAME error
    // in both cases — code `USER_NOT_SIGNED_IN`, which the SDK raises for both a
    // definitive rejection and a transient `/users/me` failure, and which the
    // error mapper classifies as `preserveCachedSession`. The outcome must instead
    // be decided by LIVE token-store validity, so these two tests throw the
    // identical error and differ only in whether a refresh token survives.
    private static func userNotSignedInError() -> any Error {
        StackAuthError(code: "USER_NOT_SIGNED_IN", message: "User is not signed in.")
    }

    // Definitively gone: validation throws and no refresh token survives in the
    // live store. The stale "signed in" flag must NOT outlive the tokens; the
    // gate routes to the sign-in page. A non-nil access token is present so
    // `checkExistingSession` reaches `validateCachedSession` (its `hasStoredTokens`
    // gate is `access != nil || refresh != nil`) and the catch discriminator runs.
    @Test func validationFailureWithNoRefreshTokenRoutesToLogin() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        await client.setTokens(access: "stale", refresh: nil)
        await client.setThrowOnCurrentUser(Self.userNotSignedInError())

        await coordinator.revalidateSession()

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    // Transient: validation throws the same error, but a refresh token survives,
    // so the failure was a network/server hiccup and the cached session is
    // preserved (a flaky network must never sign a valid user out).
    @Test func validationFailureWithSurvivingRefreshTokenPreservesSession() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = try await signedInCoordinator(client: client)

        await client.setTokens(access: "a", refresh: "r")
        await client.setThrowOnCurrentUser(Self.userNotSignedInError())

        await coordinator.revalidateSession()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens") == true)
    }
}
