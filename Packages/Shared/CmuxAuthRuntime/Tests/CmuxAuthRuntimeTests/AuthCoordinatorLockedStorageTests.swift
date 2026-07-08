import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

actor LockedStorageAuthClient: AuthClient {
    private var access: String?
    private var refresh: String?
    private var user: CMUXAuthUser?
    private var locked: Bool
    private(set) var clearLocalSessionCallCount = 0

    init(
        access: String? = nil,
        refresh: String? = nil,
        user: CMUXAuthUser? = nil,
        locked: Bool
    ) {
        self.access = access
        self.refresh = refresh
        self.user = user
        self.locked = locked
    }

    func unlock() {
        locked = false
    }

    func accessToken() async -> String? {
        locked ? nil : access
    }

    func refreshToken() async -> String? {
        locked ? nil : refresh
    }

    func forceRefreshAccessToken() async -> String? {
        locked ? nil : access
    }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        user
    }

    func listTeams() async throws -> [CMUXAuthTeam] {
        []
    }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        "nonce"
    }

    func signInWithMagicLink(code: String) async throws {
        access = "access"
        refresh = "refresh"
    }

    func signInWithCredential(email: String, password: String) async throws {
        access = "access"
        refresh = "refresh"
    }

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        access = "access"
        refresh = "refresh"
    }

    func storedAccessToken() async -> String? {
        locked ? nil : access
    }

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

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? {
        locked ? nil : accessToken ?? access
    }
}

actor TokenStorageAvailabilityProbe {
    private var available: Bool

    init(available: Bool) {
        self.available = available
    }

    func setAvailable(_ available: Bool) {
        self.available = available
    }

    func isAvailable() -> Bool {
        available
    }
}

@MainActor
@Suite struct AuthCoordinatorLockedStorageTests {
    private func makeCoordinator(
        client: LockedStorageAuthClient,
        cachedUser: CMUXAuthUser,
        availability: TokenStorageAvailabilityProbe
    ) throws -> (AuthCoordinator, FakeKeyValueStore) {
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
            launch: .plain(),
            isTokenStorageAvailable: { await availability.isAvailable() }
        )
        return (coordinator, store)
    }

    @Test func lockedLaunchPreservesCachedSessionAndRevalidatesAfterUnlock() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let validatedUser = CMUXAuthUser(id: "validated", primaryEmail: "valid@example.com", displayName: "Validated")
        let client = LockedStorageAuthClient(
            access: "access",
            refresh: "refresh",
            user: validatedUser,
            locked: true
        )
        let availability = TokenStorageAvailabilityProbe(available: false)
        let (coordinator, store) = try makeCoordinator(
            client: client,
            cachedUser: cachedUser,
            availability: availability
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == cachedUser)
        #expect(store.bool(forKey: "has_tokens") == true)
        #expect(await client.clearLocalSessionCallCount == 0)

        await client.unlock()
        await availability.setAvailable(true)
        await coordinator.revalidateSession()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == validatedUser)
    }

    @Test func availableEmptyStorageClearsSeededCache() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let client = LockedStorageAuthClient(access: nil, refresh: nil, user: nil, locked: false)
        let availability = TokenStorageAvailabilityProbe(available: true)
        let (coordinator, store) = try makeCoordinator(
            client: client,
            cachedUser: cachedUser,
            availability: availability
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
    }

    @Test func unavailableEmptyTokenReadIsRetryableButAvailableEmptyReadIsUnauthorized() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let client = LockedStorageAuthClient(access: nil, refresh: nil, user: nil, locked: false)
        let availability = TokenStorageAvailabilityProbe(available: false)
        let (coordinator, store) = try makeCoordinator(
            client: client,
            cachedUser: cachedUser,
            availability: availability
        )

        await #expect(throws: AuthError.networkError) {
            _ = try await coordinator.accessToken()
        }
        #expect(store.bool(forKey: "has_tokens") == true)
        #expect(coordinator.isAuthenticated == true)

        await availability.setAvailable(true)
        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.accessToken()
        }
    }
}
