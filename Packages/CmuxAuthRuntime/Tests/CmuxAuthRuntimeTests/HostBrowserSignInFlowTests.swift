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

    private func makeHarness(
        user: CMUXAuthUser? = nil,
        browserAttemptTimeout: TimeInterval = 5 * 60
    ) -> Harness {
        let store = FakeKeyValueStore()
        // The fake client reads and clears the SAME token store the flow
        // seeds, like production (StackAuthClient wraps the StackClientApp
        // built over the store the callback seeds into). Split stores would
        // hide races between the flow's seed handling and the coordinator's
        // capture/clear sequence.
        let tokenStore = FlowInMemoryTokenStore()
        let client = FlowFakeAuthClient(user: user, store: tokenStore)
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        let factory = FakeBrowserAuthSessionFactory()
        let flow = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: factory,
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\($0)")! },
            callbackScheme: { "cmux-dev" },
            browserAttemptTimeout: browserAttemptTimeout
        )
        return Harness(flow: flow, coordinator: coordinator, client: client, tokenStore: tokenStore, factory: factory)
    }

    private func callbackURL(state: String) -> URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1&cmux_auth_state=\(state)")!
    }

    private func fallbackCallbackURL() -> URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1")!
    }

    private func callbackState(_ session: FakeBrowserAuthSession) -> String {
        URLComponents(url: session.signInURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value ?? ""
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
        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))

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
        harness.factory.sessions[0].deliver(URL(string: "cmux-dev://auth-callback?other=1&cmux_auth_state=\(callbackState(harness.factory.sessions[0]))")!)

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func nonAuthBrowserCompletionWaitsForExternalCallback() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(URL(string: "https://example.test/handler/sign-in?after_auth_return_to=1")!)

        await Task.yield()
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)

        let callbackResult = await harness.flow.handleCallbackURL(callbackURL(state: callbackState(harness.factory.sessions[0])))

        #expect(callbackResult)
        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(harness.flow.isSigningIn == false)
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

    @Test func staleSessionCompletionCannotResumeNewAttempt() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        harness.flow.beginSignIn()
        await waitForSession(harness.factory)
        let staleSession = harness.factory.sessions[0]
        staleSession.deliverCancelCompletion = false

        let secondAttempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory, count: 2)
        staleSession.deliver(callbackURL(state: callbackState(staleSession)))

        await Task.yield()
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)

        harness.factory.sessions[1].deliver(callbackURL(state: callbackState(harness.factory.sessions[1])))

        #expect(await secondAttempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
    }

    @Test func abandonedBrowserAttemptTimesOut() async throws {
        let harness = makeHarness(browserAttemptTimeout: 0.01)

        harness.flow.beginSignIn()
        await waitForSession(harness.factory)

        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func signOutDuringCallbackValidationWins() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))
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

    @Test func attemptTimeoutDoesNotCancelValidationAfterCallbackArrives() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user, browserAttemptTimeout: 0.01)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))
        while await harness.client.pendingUserRequests == 0 {
            await Task.yield()
        }

        try await Task.sleep(for: .milliseconds(50))
        await harness.client.openUserGate()

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func deadlineResolvesFalseWhilePopupStaysUp() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let result = await harness.flow.signIn(timeout: 0.05)
        #expect(result == false)
        #expect(harness.factory.sessions.count == 1)
        #expect(harness.factory.sessions[0].cancelled == false)

        // The user can still finish in the popup after the caller's deadline.
        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))
        while harness.coordinator.isAuthenticated == false {
            await Task.yield()
        }
        #expect(harness.coordinator.currentUser == user)
    }

    @Test func lateCallbackAfterSignOutIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        harness.flow.beginSignIn()
        await waitForSession(harness.factory)
        let staleCallback = callbackURL(state: callbackState(harness.factory.sessions[0]))
        await harness.flow.signOut()

        let result = await harness.flow.handleCallbackURL(staleCallback)

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func mismatchedCallbackStateIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL(state: "stale-state"))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func staleExternalCallbackDoesNotCancelActiveAttempt() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)

        let staleResult = await harness.flow.handleCallbackURL(callbackURL(state: "stale-state"))

        #expect(staleResult == false)
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)

        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func fallbackExternalCallbackWithoutActiveAttemptSignsIn() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let result = await harness.flow.handleCallbackURL(fallbackCallbackURL())

        #expect(result)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func statefulExternalCallbackWithoutActiveAttemptIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)

        let result = await harness.flow.handleCallbackURL(callbackURL(state: "stale-state"))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func signOutDuringCallbackValidationStillRevokesWithCapturedCredentials() async {
        // flow.signOut() advances the flow's sign-out generation BEFORE the
        // coordinator captures the teardown credentials with raw store reads.
        // If the parked callback validation resumes inside that capture
        // window, a flow-side seed clear runs first, the capture reads an
        // empty store, and the best-effort server teardown (push unregister,
        // session revocation) silently loses its credentials even though the
        // device is online. The coordinator owns the local clear AFTER the
        // capture; the flow must not clear the shared store underneath it.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = makeHarness(user: user)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForSession(harness.factory)
        harness.factory.sessions[0].deliver(callbackURL(state: callbackState(harness.factory.sessions[0])))
        while await harness.client.pendingUserRequests == 0 {
            await Task.yield()
        }

        // Sign-out parks inside its credential capture, before its local
        // clear.
        await harness.client.armStoredAccessTokenGate()
        let signOut = Task { await harness.flow.signOut() }
        await harness.client.storedAccessTokenDidPark()

        // The parked validation resumes and fails as cancelled while
        // sign-out is still inside the capture window.
        await harness.client.openUserGate()
        #expect(await attempt.value == false)

        // Sign-out proceeds: capture, local-first clear, bounded revocation.
        await harness.client.releaseStoredAccessTokenGate()
        await signOut.value

        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
        // The teardown must authenticate as the signed-out session.
        let revoked = await harness.client.revokedCredentials
        #expect(revoked.count == 1)
        #expect(revoked.first?.access == "access-1")
        #expect(revoked.first?.refresh == "refresh-1")
    }
}

// MARK: - Fakes

/// Scriptable ``AuthClient`` backed by the same token store the flow seeds
/// (like production), with a gate on `currentUser` so tests can hold the
/// callback-completion round trip open while a sign-out races it, and a gate
/// on `storedAccessToken` so tests can park sign-out inside its credential
/// capture window.
private actor FlowFakeAuthClient: AuthClient {
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
        let session = FakeBrowserAuthSession(signInURL: signInURL, completion: completion)
        sessions.append(session)
        return session
    }
}

/// Delivers its completion exactly once, mirroring `ASWebAuthenticationSession`.
@MainActor
private final class FakeBrowserAuthSession: HostBrowserAuthSession {
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
