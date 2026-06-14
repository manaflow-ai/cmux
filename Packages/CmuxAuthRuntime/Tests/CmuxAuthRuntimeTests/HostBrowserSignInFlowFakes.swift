import AuthenticationServices
import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

// MARK: - Fakes

/// Scriptable ``AuthClient`` backed by the same token store the flow seeds
/// (like production), with a gate on `currentUser` so tests can hold the
/// callback-completion round trip open while a sign-out races it, and a gate
/// on `storedAccessToken` so tests can park sign-out inside its credential
/// capture window.
actor FlowFakeAuthClient: AuthClient {
    private var user: CMUXAuthUser?
    private let store: FlowInMemoryTokenStore
    private(set) var pendingUserRequests = 0
    private var userGateClosed = false
    private var userGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var storedAccessGateArmed = false
    private var storedAccessParked: [CheckedContinuation<Void, Never>] = []
    private var storedAccessParkWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var revokedCredentials: [(access: String?, refresh: String?)] = []

    init(user: CMUXAuthUser?, store: FlowInMemoryTokenStore) {
        self.user = user
        self.store = store
    }

    func closeUserGate() { userGateClosed = true }

    func openUserGate() {
        userGateClosed = false
        let waiters = userGateWaiters
        userGateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func armStoredAccessTokenGate() { storedAccessGateArmed = true }

    /// Suspends until a `storedAccessToken` read is parked on the armed gate.
    func storedAccessTokenDidPark() async {
        if !storedAccessParked.isEmpty { return }
        await withCheckedContinuation { storedAccessParkWaiters.append($0) }
    }

    func releaseStoredAccessTokenGate() {
        let parked = storedAccessParked
        storedAccessParked = []
        for continuation in parked { continuation.resume() }
    }

    func accessToken() async -> String? { await store.getStoredAccessToken() }
    func refreshToken() async -> String? { await store.getStoredRefreshToken() }
    func forceRefreshAccessToken() async -> String? { await store.getStoredAccessToken() }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if userGateClosed {
            pendingUserRequests += 1
            await withCheckedContinuation { userGateWaiters.append($0) }
            pendingUserRequests -= 1
        }
        return user
    }

    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}

    func storedAccessToken() async -> String? {
        if storedAccessGateArmed {
            storedAccessGateArmed = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                storedAccessParked.append(continuation)
                let waiters = storedAccessParkWaiters
                storedAccessParkWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return await store.getStoredAccessToken()
    }

    func clearLocalSession() async {
        await store.clearTokens()
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        await store.compareAndSet(
            compareRefreshToken: refreshToken,
            newRefreshToken: nil,
            newAccessToken: nil
        )
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        revokedCredentials.append((access: accessToken, refresh: refreshToken))
    }

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}

/// In-memory ``StackAuthTokenStoreProtocol`` fake.
actor FlowInMemoryTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?

    func getStoredAccessToken() async -> String? { accessToken }
    func getStoredRefreshToken() async -> String? { refreshToken }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard refreshToken == compareRefreshToken else { return }
        refreshToken = newRefreshToken
        accessToken = newAccessToken
    }
}

/// Records created browser sessions and lets tests deliver their callbacks.
@MainActor
final class FakeBrowserAuthSessionFactory: HostBrowserAuthSessionFactory {
    private(set) var sessions: [FakeBrowserAuthSession] = []

    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (URL?) -> Void
    ) -> any HostBrowserAuthSession {
        let session = FakeBrowserAuthSession(signInURL: signInURL, completion: completion)
        sessions.append(session)
        return session
    }
}

/// Delivers its completion exactly once, mirroring `ASWebAuthenticationSession`.
@MainActor
final class FakeBrowserAuthSession: HostBrowserAuthSession {
    let signInURL: URL
    var deliverCancelCompletion = true
    private let completion: @MainActor (URL?) -> Void
    private var completed = false
    private(set) var cancelled = false

    init(signInURL: URL, completion: @escaping @MainActor (URL?) -> Void) {
        self.signInURL = signInURL
        self.completion = completion
    }

    func start() -> Bool { true }

    func cancel() {
        cancelled = true
        if deliverCancelCompletion {
            deliver(nil)
        }
    }

    func deliver(_ url: URL?) {
        guard !completed else { return }
        completed = true
        completion(url)
    }
}
