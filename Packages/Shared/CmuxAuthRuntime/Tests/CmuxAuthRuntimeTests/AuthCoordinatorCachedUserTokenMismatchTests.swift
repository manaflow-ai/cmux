import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

/// The cached user and the token store are written apart, so a launch can find user A cached beside user B's
/// tokens (two probe accounts on one Mac). An install bound to A with B's token is refused as "the cmux API
/// answered for another user": restore must never publish A for B's session, also when validation fails.
@MainActor
@Suite struct AuthCoordinatorCachedUserTokenMismatchTests {
    private let userA = CMUXAuthUser(id: "user-a", primaryEmail: "a@example.com", displayName: "A")
    private let userB = CMUXAuthUser(id: "user-b", primaryEmail: "b@example.com", displayName: "B")

    /// An unsigned JWT whose `sub` is `subject` (the coordinator reads claims only, never the signature).
    private static func token(subject: String) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return segment(["alg": "ES256", "typ": "JWT"]) + "." + segment(["sub": subject, "exp": 4_102_444_800]) + ".sig"
    }

    private func launch(cached: CMUXAuthUser, client: some AuthClient) throws -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        sessionCache.setHasTokens(true)
        try userCache.save(cached)
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        return (coordinator, store)
    }

    private func cachedUser(in store: FakeKeyValueStore) throws -> CMUXAuthUser? {
        try CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user").load()
    }

    @Test func restoreWithAnotherAccountsTokenPublishesTheTokensUser() async throws {
        let client = FakeAuthClient(access: Self.token(subject: userB.id), refresh: "refresh-b", user: userB)
        let (coordinator, store) = try launch(cached: userA, client: client)
        #expect(coordinator.currentUser == userA) // primed from the cache before restore

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == userB)
        #expect(try cachedUser(in: store) == userB)
    }

    /// AuthCoordinator's validation-failure path keeps the cached session; it must not keep A for B's token.
    @Test func failedValidationWithAnotherAccountsTokenKeepsNoStaleUser() async throws {
        let client = FakeAuthClient(access: Self.token(subject: userB.id), refresh: "refresh-b", user: userB)
        await client.setThrowOnCurrentUser(StackAuthError(code: "USER_NOT_SIGNED_IN", message: "User is not signed in."))
        let (coordinator, store) = try launch(cached: userA, client: client)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.currentUser == nil)
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.isRestoringSession == false)
        #expect(try cachedUser(in: store) == nil)
        // The tokens are the session: kept, so the next revalidation publishes B.
        #expect(await client.clearLocalSessionCount == 0)
        #expect(await client.refreshToken() == "refresh-b")
        #expect(store.bool(forKey: "has_tokens") == true)

        await client.setThrowOnCurrentUser(nil)
        await coordinator.revalidateSession()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == userB)
    }

    /// While validation is still in flight, a binder reading `currentUser` must not see A.
    @Test func inFlightValidationAlreadyDroppedTheStaleUser() async throws {
        let client = GateableValidationAuthClient(user: userB)
        await client.seedTokens(access: Self.token(subject: userB.id), refresh: "refresh-b")
        await client.armValidationGate()
        let (coordinator, _) = try launch(cached: userA, client: client)

        coordinator.start()
        await client.validationDidPark()
        #expect(coordinator.currentUser?.id != userA.id)
        #expect(coordinator.isRestoringSession)

        await client.releaseParkedValidation()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.currentUser == userB)
    }

    @Test func matchingTokenKeepsTheCachedUserThroughAFailedValidation() async throws {
        let client = FakeAuthClient(access: Self.token(subject: userA.id), refresh: "refresh-a", user: userA)
        await client.setThrowOnCurrentUser(StackAuthError(code: "USER_NOT_SIGNED_IN", message: "User is not signed in."))
        let (coordinator, store) = try launch(cached: userA, client: client)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == userA)
        #expect(try cachedUser(in: store) == userA)
    }

    @Test func subjectReadsOnlyAJWTsSubClaim() {
        #expect(AccessTokenClaims.subject(Self.token(subject: "user-b")) == "user-b")
        #expect(AccessTokenClaims.subject("opaque") == nil)
        #expect(AccessTokenClaims.subject(nil) == nil)
    }
}
