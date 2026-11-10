import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// A token store fake whose first `failingReads` reads fail with a storage
/// error (nil plus a bumped ``tokenReadFailureCount()``, as a keychain read
/// refused with -25293 or `errSecInteractionNotAllowed` does), then answers
/// with what it holds. Holding nothing, it answers a definite "not found".
actor FailingReadsTokenStoreAuthClient: AuthClient {
    private var access: String?
    private var refresh: String?
    private let user: CMUXAuthUser?
    private var failingReads: Int
    private var readFailures: UInt64 = 0
    private(set) var clearLocalSessionCallCount = 0

    init(access: String?, refresh: String?, user: CMUXAuthUser?, failingReads: Int) {
        self.access = access
        self.refresh = refresh
        self.user = user
        self.failingReads = failingReads
    }

    func failForever() { failingReads = .max }

    private func read(_ value: String?) -> String? {
        if failingReads > 0 {
            failingReads -= 1
            readFailures &+= 1
            return nil
        }
        return value
    }

    func tokenReadFailureCount() async -> UInt64 { readFailures }
    func accessToken() async -> String? { read(access) }
    func refreshToken() async -> String? { read(refresh) }
    func forceRefreshAccessToken() async -> String? { read(access) }
    func storedAccessToken() async -> String? { read(access) }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { user }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func clearLocalSession() async {
        clearLocalSessionCallCount += 1
        access = nil
        refresh = nil
    }
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        clearLocalSessionCallCount += 1
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}

/// manaflow-ai/cmuxterm-hq#8831: NIGHTLY came up signed out after a keychain
/// miss at launch, and the sign-out logged no reason.
@MainActor
@Suite struct AuthCoordinatorFailedTokenReadTests {
    private let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")

    private func makeCoordinator(client: FailingReadsTokenStoreAuthClient) throws -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        sessionCache.setHasTokens(true)
        try userCache.save(cachedUser)
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

    @Test func tokenReadsThatFailTwiceThenSucceedKeepTheSessionSignedIn() async throws {
        let validatedUser = CMUXAuthUser(id: "validated", primaryEmail: "valid@example.com", displayName: "Validated")
        // The launch probe reads access then refresh: both fail on the first
        // pass, so it takes a retry to read the stored tokens.
        let client = FailingReadsTokenStoreAuthClient(
            access: "access", refresh: "refresh", user: validatedUser, failingReads: 2
        )
        let (coordinator, store) = try makeCoordinator(client: client)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == validatedUser)
        #expect(store.bool(forKey: "has_tokens") == true)
        #expect(coordinator.lastSignOutReason == nil)
        #expect(await client.clearLocalSessionCallCount == 0)
    }

    @Test func tokenReadsThatKeepFailingKeepTheCachedSessionAndStayRetryable() async throws {
        let client = FailingReadsTokenStoreAuthClient(
            access: "access", refresh: "refresh", user: nil, failingReads: 0
        )
        await client.failForever()
        let (coordinator, store) = try makeCoordinator(client: client)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == cachedUser)
        #expect(store.bool(forKey: "has_tokens") == true)
        #expect(coordinator.lastSignOutReason == nil)

        // The next auth use reads again; a failed read stays retryable and
        // never signs out.
        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.accessToken()
        }
        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.lastSignOutReason == nil)
        #expect(await client.clearLocalSessionCallCount == 0)
    }

    @Test func aDefiniteNotFoundSignsOutWithAReasonLogged() async throws {
        let client = FailingReadsTokenStoreAuthClient(
            access: nil, refresh: nil, user: nil, failingReads: 0
        )
        let (coordinator, store) = try makeCoordinator(client: client)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(coordinator.lastSignOutReason == "launch restore found no stored tokens in readable storage")
    }
}
