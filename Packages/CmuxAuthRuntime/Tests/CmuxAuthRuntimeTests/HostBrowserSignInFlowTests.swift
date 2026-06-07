import AuthenticationServices
import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Behavior tests for the hosted-browser sign-in flow: callback completion,
/// the sign-out-vs-callback race guards, deadlines, and attempt cancellation.
@MainActor
@Suite struct HostBrowserSignInFlowTests {
    private struct Harness {
        let flow: HostBrowserSignInFlow
        let coordinator: AuthCoordinator
        let client: FlowFakeAuthClient
        let tokenStore: FlowInMemoryTokenStore
        let factory: FakeBrowserAuthSessionFactory
    }

    private func makeHarness(user: CMUXAuthUser? = nil) -> Harness {
        let store = FakeKeyValueStore()
        let client = FlowFakeAuthClient(user: user)
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        let tokenStore = FlowInMemoryTokenStore()
        let factory = FakeBrowserAuthSessionFactory()
        let flow = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: factory,
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { URL(string: "https://example.test/handler/sign-in")! },
            callbackScheme: { "cmux-dev" }
        )
        return Harness(flow: flow, coordinator: coordinator, client: client, tokenStore: tokenStore, factory: factory)
    }

    private var callbackURL: URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1")!
    }

    private func waitForSession(_ factory: FakeBrowserAuthSessionFactory, count: Int = 1) async {
        // The attempt task runs on the same main actor; yielding lets it reach
        // the browser-session continuation deterministically.
        while factory.sessions.count < count {
            await Task.yield()
        }
    }

    @Test func browserCallbackSignsInAndSeedsTokens() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL)

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(harness.flow.isSigningIn == false)
    }

    @Test func invalidCallbackPayloadIsRejected() async {
        let harness = makeHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(URL(string: "cmux-dev://auth-callback?other=1")!)

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func cancelledPopupResolvesFalse() async {
        let harness = makeHarness()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].cancel()

        #expect(await attempt.value == false)
        #expect(harness.flow.isSigningIn == false)
    }

    @Test func signOutCancelsActivePopup() async {
        let harness = makeHarness()

        harness.flow.beginSignIn()
        await waitForSession(harness.factory)
        await harness.flow.signOut()

        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func newAttemptCancelsPreviousPopup() async {
        let harness = makeHarness()

        harness.flow.beginSignIn()
        await waitForSession(harness.factory)
        harness.flow.beginSignIn()
        await waitForSession(harness.factory, count: 2)

        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.factory.sessions[1].cancelled == false)
        #expect(harness.flow.isSigningIn)
    }

    @Test func signOutDuringCallbackValidationWins() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL)
        // Wait until the completion path is blocked inside the user fetch.
        while await harness.client.pendingUserRequests == 0 {
            await Task.yield()
        }

        await harness.flow.signOut()
        await harness.client.openUserGate()

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.coordinator.currentUser == nil)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func deadlineResolvesFalseWhilePopupStaysUp() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let result = await harness.flow.signIn(timeout: 0.05)
        #expect(result == false)
        #expect(harness.factory.sessions.count == 1)
        #expect(harness.factory.sessions[0].cancelled == false)

        // The user can still finish in the popup after the caller's deadline.
        harness.factory.sessions[0].deliver(callbackURL)
        while harness.coordinator.isAuthenticated == false {
            await Task.yield()
        }
        #expect(harness.coordinator.currentUser == user)
    }
}

// MARK: - Fakes

/// Scriptable ``AuthClient`` with a gate on `currentUser` so tests can hold the
/// callback-completion round trip open while a sign-out races it.
private actor FlowFakeAuthClient: AuthClient {
    private var user: CMUXAuthUser?
    private(set) var pendingUserRequests = 0
    private var userGateClosed = false
    private var userGateWaiters: [CheckedContinuation<Void, Never>] = []

    init(user: CMUXAuthUser?) {
        self.user = user
    }

    func closeUserGate() { userGateClosed = true }

    func openUserGate() {
        userGateClosed = false
        let waiters = userGateWaiters
        userGateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }

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
    func signOut() async throws {}
}

/// In-memory ``StackAuthTokenStoreProtocol`` fake.
private actor FlowInMemoryTokenStore: StackAuthTokenStoreProtocol {
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
private final class FakeBrowserAuthSessionFactory: HostBrowserAuthSessionFactory {
    private(set) var sessions: [FakeBrowserAuthSession] = []

    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (URL?) -> Void
    ) -> any HostBrowserAuthSession {
        let session = FakeBrowserAuthSession(completion: completion)
        sessions.append(session)
        return session
    }
}

/// Delivers its completion exactly once, mirroring `ASWebAuthenticationSession`.
@MainActor
private final class FakeBrowserAuthSession: HostBrowserAuthSession {
    private let completion: @MainActor (URL?) -> Void
    private var completed = false
    private(set) var cancelled = false

    init(completion: @escaping @MainActor (URL?) -> Void) {
        self.completion = completion
    }

    func start() -> Bool { true }

    func cancel() {
        cancelled = true
        deliver(nil)
    }

    func deliver(_ url: URL?) {
        guard !completed else { return }
        completed = true
        completion(url)
    }
}
