import AuthenticationServices
import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Behavior tests for the hosted-browser sign-in flow: callback completion,
/// the sign-out-vs-callback race guards, deadlines, and attempt cancellation.
@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowTests {
    @Test func browserCallbackSignsInAndSeedsTokens() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(harness.flow.isSigningIn == false)
    }

    @Test func cancelledPopupResolvesFalse() async {
        let harness = HostBrowserSignInFlowHarness()
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].cancel()

        #expect(await attempt.value == false)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.flow.lastFailure == nil)
    }

    @Test func signOutCancelsActivePopup() async {
        let harness = HostBrowserSignInFlowHarness()

        harness.flow.beginSignIn()
        await harness.waitForSession()
        await harness.flow.signOut()

        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func newAttemptCancelsPreviousPopup() async {
        let harness = HostBrowserSignInFlowHarness()

        harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)

        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.factory.sessions[1].cancelled == false)
        #expect(harness.flow.isSigningIn)
    }

    @Test func staleSessionCompletionCannotResumeNewAttempt() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let staleSession = harness.factory.sessions[0]
        staleSession.deliverCancelCompletion = false

        let secondAttempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession(count: 2)
        staleSession.deliver(harness.callbackURL(state: harness.callbackState(staleSession)))

        await Task.yield()
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)

        harness.factory.sessions[1].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[1])))

        #expect(await secondAttempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
    }

    @Test func abandonedBrowserAttemptTimesOut() async throws {
        // Drive the abandoned-attempt timeout off a virtual clock so the result
        // does not depend on a real-timer task being scheduled within a fixed
        // wall-clock window. beginSignIn parks two sleepers on this clock: the
        // attempt timeout (1s here) and the slow-sign-in hint (30s default).
        let clock = ManualTestClock()
        let harness = HostBrowserSignInFlowHarness(browserAttemptTimeout: 1, clock: clock)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        await clock.waitUntilSleepers(count: 2)

        // Advance past the attempt timeout but well under the 30s slow-hint
        // threshold, so only the abandoned-attempt timeout fires.
        clock.advance(by: .seconds(1))

        await harness.waitForCondition { harness.flow.isSigningIn == false }
        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func slowSignInSurfacesBrowserFallback() async {
        // A popup that never delivers a callback models the issue #6015 hang:
        // ASWebAuthenticationSession opens its Safari window but the hosted
        // page never redirects to cmux://auth-callback, so the user is left
        // staring at a dead window. Past the slow threshold the flow must flip
        // `signInIsSlow` so the account UI can offer the "open in your default
        // browser" fallback instead of an indefinite spinner.
        // Drive the slow-sign-in deadline off a virtual clock so the result does
        // not depend on a real-timer task being scheduled within a fixed
        // wall-clock window. beginSignIn parks two sleepers on this clock: the
        // attempt timeout (default 5min) and the slow-sign-in hint (1s here).
        let clock = ManualTestClock()
        let harness = HostBrowserSignInFlowHarness(slowSignInThreshold: 1, clock: clock)
        #expect(harness.flow.signInIsSlow == false)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        await clock.waitUntilSleepers(count: 2)

        // Advance past the slow-sign-in threshold but well under the 5min
        // attempt timeout, so only the slow-sign-in hint fires.
        clock.advance(by: .seconds(1))

        await harness.waitForCondition { harness.flow.signInIsSlow }
        #expect(harness.flow.signInIsSlow)

        // Resolving the attempt clears the slow flag so a later sign-in starts
        // from a clean slate.
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition {
            harness.flow.signInIsSlow == false && harness.flow.isSigningIn == false
        }
        #expect(!harness.flow.signInIsSlow)
        #expect(!harness.flow.isSigningIn)
    }

    @Test func activeAttemptSignInURLCarriesActiveAttemptState() async {
        let harness = HostBrowserSignInFlowHarness()
        #expect(harness.flow.activeAttemptSignInURL == nil)

        harness.flow.beginSignIn()
        await harness.waitForSession()

        let fallbackURL = harness.flow.activeAttemptSignInURL
        #expect(fallbackURL != nil)
        // The default-browser fallback must carry the same callback state as
        // the popup so the cmux:// deep link routes back to THIS attempt —
        // handleCallbackURL matches on cmux_auth_state.
        let fallbackState = fallbackURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "cmux_auth_state" })?
                .value
        }
        #expect(fallbackState == harness.callbackState(harness.factory.sessions[0]))
    }

    @Test func issuedFallbackCallbackSurvivesPopupCancellation() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let fallbackState = try #require(URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value)

        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        let callbackResult = await harness.flow.handleCallbackURL(harness.callbackURL(state: fallbackState))

        #expect(callbackResult)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func manualFallbackURLCallbackSurvivesPopupCancellation() async throws {
        // Regression for the iOS-pairing "stuck on Checking…" bug (#6158).
        // The CLI `cmux auth login` flow requests the manual fallback URL
        // (`auth.sign_in_url` -> `manualSignInURL`) BEFORE it starts the popup
        // attempt (`auth.begin_sign_in`), so the popup and the printed fallback
        // URL deliberately share one callback state. When the system popup
        // auto-dismisses without completing the handoff, the attempt ends — but a
        // callback later delivered from the manually opened fallback URL must
        // still complete sign-in instead of being rejected as "noActiveAttempt"
        // and leaving `auth.status` stuck at signed_in=false.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        // auth.sign_in_url: issue the manual fallback URL up front.
        let manualURL = harness.flow.manualSignInURL
        let manualState = try #require(URLComponents(url: manualURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value)

        // auth.begin_sign_in: start the popup attempt, which consumes that state
        // so the popup and the printed fallback URL share one callback state.
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        #expect(harness.callbackState(harness.factory.sessions[0]) == manualState)

        // The system popup auto-dismisses without completing the handoff.
        harness.factory.sessions[0].cancel()
        #expect(await attempt.value == false)
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        // The user finishes sign-in in their own browser and returns to the app
        // via the manual fallback URL's callback.
        let callbackResult = await harness.flow.handleCallbackURL(harness.callbackURL(state: manualState))

        #expect(callbackResult)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func issuedFallbackCallbackStateSurvivesFailedRetryAndClearsFailureOnSuccess() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let fallbackState = try #require(URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value)

        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        let failedRetry = URL(string: "cmux-dev://auth-callback?other=1&cmux_auth_state=\(fallbackState)")!
        #expect(await harness.flow.handleCallbackURL(failedRetry) == false)
        #expect(harness.flow.lastFailure == .invalidCallback)
        #expect(harness.coordinator.isAuthenticated == false)

        let validRetry = await harness.flow.handleCallbackURL(harness.callbackURL(state: fallbackState))

        #expect(validRetry)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(harness.flow.lastFailure == nil)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func issuedFallbackCallbackAfterSignOutIsRejected() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let fallbackState = try #require(URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value)

        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }
        await harness.flow.signOut()

        let callbackResult = await harness.flow.handleCallbackURL(harness.callbackURL(state: fallbackState))

        #expect(callbackResult == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func signOutDuringCallbackValidationWins() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))
        // Wait until the completion path is blocked inside the user fetch.
        await harness.waitForPendingUserRequest()

        await harness.flow.signOut()
        await harness.client.openUserGate()

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.coordinator.currentUser == nil)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func attemptTimeoutDoesNotCancelValidationAfterCallbackArrives() async throws {
        // Drive the abandoned-attempt timeout off a virtual clock so the result
        // depends on the timeout deadline actually elapsing, not on a real timer
        // racing a fixed wall-clock window. The callback arrives first and the
        // validation parks inside the user fetch; advancing past the 1s attempt
        // timeout while validation is parked must NOT cancel that validation
        // (the callback path already cancelled the timeout before parking).
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user, browserAttemptTimeout: 1, clock: clock)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))
        await harness.waitForPendingUserRequest()

        // Past the 1s attempt timeout, but well under both the 30s slow-hint
        // threshold and the 60s caller deadline, so only the abandoned-attempt
        // timeout could fire. The callback already cancelled it, so this is a
        // no-op for the parked validation.
        clock.advance(by: .seconds(1))
        await harness.client.openUserGate()

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func deadlineResolvesFalseWhilePopupStaysUp() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let result = await harness.flow.signIn(timeout: 0.05)
        #expect(result == false)
        #expect(harness.factory.sessions.count == 1)
        #expect(harness.factory.sessions[0].cancelled == false)

        // The user can still finish in the popup after the caller's deadline.
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))
        await harness.waitForCondition { harness.coordinator.isAuthenticated }
        #expect(harness.coordinator.currentUser == user)
    }

    @Test func lateCallbackAfterSignOutIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let staleCallback = harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0]))
        await harness.flow.signOut()

        let result = await harness.flow.handleCallbackURL(staleCallback)

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
        #expect(harness.flow.lastFailure == nil)
    }

    @Test func mismatchedCallbackStateIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: "stale-state"))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func staleExternalCallbackDoesNotCancelActiveAttempt() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()

        let staleResult = await harness.flow.handleCallbackURL(harness.callbackURL(state: "stale-state"))

        #expect(staleResult == false)
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)

        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func fallbackExternalCallbackWithoutActiveAttemptSignsIn() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let result = await harness.flow.handleCallbackURL(harness.fallbackCallbackURL())

        #expect(result)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func statefulExternalCallbackWithoutActiveAttemptIsRejected() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let result = await harness.flow.handleCallbackURL(harness.callbackURL(state: "stale-state"))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
        #expect(harness.flow.lastFailure == nil)
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
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user, clock: clock)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        await clock.waitUntilSleepers(count: 3)
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))
        await harness.waitForPendingUserRequest()

        // Sign-out parks inside its credential capture, before its local
        // clear.
        await harness.client.armStoredAccessTokenGate()
        let signOut = Task { await harness.flow.signOut() }
        await harness.client.storedAccessTokenDidPark()

        // The parked validation resumes and fails as cancelled while
        // sign-out is still inside the capture window.
        await harness.client.openUserGate()
        clock.advance(by: .seconds(60))
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
