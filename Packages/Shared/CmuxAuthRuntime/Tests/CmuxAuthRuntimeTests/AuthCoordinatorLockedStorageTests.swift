import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

actor LockedStorageAuthClient: AuthClient {
    private var access: String?
    private var refresh: String?
    private var user: CMUXAuthUser?
    private var locked: Bool
    private var lockedTokenReadsRemaining: Int
    private let locksReadsFrom: Int?
    private var tokenReadCount = 0
    private let currentUserError: (any Error)?
    private(set) var clearLocalSessionCallCount = 0

    init(
        access: String? = nil,
        refresh: String? = nil,
        user: CMUXAuthUser? = nil,
        locked: Bool,
        locksFirstReads: Int = 0,
        locksReadsFrom: Int? = nil,
        currentUserError: (any Error)? = nil
    ) {
        self.access = access
        self.refresh = refresh
        self.user = user
        self.locked = locked
        self.lockedTokenReadsRemaining = locksFirstReads
        self.locksReadsFrom = locksReadsFrom
        self.currentUserError = currentUserError
    }

    func unlock() {
        locked = false
        lockedTokenReadsRemaining = 0
    }

    private func tokenReadIsLocked() -> Bool {
        defer { tokenReadCount += 1 }
        if let locksReadsFrom, tokenReadCount >= locksReadsFrom {
            return true
        }
        if locked {
            return true
        }
        if lockedTokenReadsRemaining > 0 {
            lockedTokenReadsRemaining -= 1
            return true
        }
        return false
    }

    func accessToken() async -> String? {
        tokenReadIsLocked() ? nil : access
    }

    func refreshToken() async -> String? {
        tokenReadIsLocked() ? nil : refresh
    }

    func forceRefreshAccessToken() async -> String? {
        tokenReadIsLocked() ? nil : access
    }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if let currentUserError { throw currentUserError }
        return user
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
        tokenReadIsLocked() ? nil : access
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
        tokenReadIsLocked() ? nil : accessToken ?? access
    }
}

actor TokenStorageAvailabilityProbe {
    private var available: Bool
    private var unavailableReadsRemaining: Int
    private var scriptedResults: [Bool]

    init(available: Bool, unavailableFirstReads: Int = 0, scriptedResults: [Bool] = []) {
        self.available = available
        self.unavailableReadsRemaining = unavailableFirstReads
        self.scriptedResults = scriptedResults
    }

    func setAvailable(_ available: Bool) {
        self.available = available
    }

    func isAvailable() -> Bool {
        if !scriptedResults.isEmpty {
            return scriptedResults.removeFirst()
        }
        if unavailableReadsRemaining > 0 {
            unavailableReadsRemaining -= 1
            return false
        }
        return available
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

    @Test func unlockDuringLaunchTokenProbeRetriesAndRestoresSession() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let validatedUser = CMUXAuthUser(id: "validated", primaryEmail: "valid@example.com", displayName: "Validated")
        let client = LockedStorageAuthClient(
            access: "access",
            refresh: "refresh",
            user: validatedUser,
            locked: false,
            locksFirstReads: 2
        )
        let availability = TokenStorageAvailabilityProbe(available: true, unavailableFirstReads: 1)
        let (coordinator, store) = try makeCoordinator(
            client: client,
            cachedUser: cachedUser,
            availability: availability
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == validatedUser)
        #expect(store.bool(forKey: "has_tokens") == true)
        #expect(await client.clearLocalSessionCallCount == 0)
    }

    @Test func readBecomingUnavailableAfterSuccessfulProbePreservesCachedSession() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let client = LockedStorageAuthClient(
            access: "access",
            refresh: "refresh",
            user: nil,
            locked: false,
            locksFirstReads: 2
        )
        let availability = TokenStorageAvailabilityProbe(available: true, scriptedResults: [true, false, false])
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

    /// https://github.com/manaflow-ai/cmux/issues/25628: `/users/me` fails
    /// transiently and the Keychain locks before validation re-reads the
    /// refresh token. The empty read is the lock, not a dead session, so the
    /// stored session must survive.
    @Test func lockedRefreshReadAfterFailedValidationPreservesStoredSession() async throws {
        let cachedUser = CMUXAuthUser(id: "cached", primaryEmail: "cached@example.com", displayName: "Cached")
        let client = LockedStorageAuthClient(
            access: "access",
            refresh: "refresh",
            user: nil,
            locked: false,
            // Restore's access and refresh reads succeed; validation's
            // re-read of the refresh token hits the locked Keychain.
            locksReadsFrom: 2,
            currentUserError: StackAuthError(code: "USER_NOT_SIGNED_IN", message: "User is not signed in.")
        )
        // Before restore, after restore's reads, after validation's re-read.
        let availability = TokenStorageAvailabilityProbe(available: true, scriptedResults: [true, true, false])
        let (coordinator, store) = try makeCoordinator(
            client: client,
            cachedUser: cachedUser,
            availability: availability
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        #expect(await client.clearLocalSessionCallCount == 0)
        #expect(coordinator.isAuthenticated == true)
        #expect(coordinator.currentUser == cachedUser)
        #expect(store.bool(forKey: "has_tokens") == true)
    }
}
