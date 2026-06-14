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
