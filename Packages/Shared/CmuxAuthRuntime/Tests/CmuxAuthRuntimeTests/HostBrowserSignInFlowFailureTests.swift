import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct HostBrowserSignInFlowFailureTests {
    @Test func invalidCallbackPayloadIsRejected() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(URL(string: "cmux-dev://auth-callback?other=1&cmux_auth_state=\(harness.callbackState(harness.factory.sessions[0]))")!)

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(harness.flow.lastFailure == .invalidCallback)
    }

    @Test func externalCallbackStateMismatchRecordsInvalidCallbackFailure() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()

        let result = await harness.flow.handleCallbackURL(harness.callbackURL(state: "other-state"))

        #expect(result == false)
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .invalidCallback)

        harness.factory.sessions[0].cancel()
        #expect(await attempt.value == false)
    }

    @Test func callbackAfterRelaunchReportsFailureAndFreshSignInCanRetry() async throws {
        let previousLaunch = HostBrowserSignInFlowHarness()
        let signInURL = previousLaunch.flow.manualSignInURL
        let state = try #require(URLComponents(url: signInURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "cmux_auth_state" })?.value)
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: state)) == false)
        #expect(harness.flow.lastFailure == .invalidCallback)
        #expect(harness.flow.isPresentingSignIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)

        let retry = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        #expect(harness.flow.lastFailure == nil)
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await retry.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.flow.lastFailure == nil)
    }

    @Test func lateMalformedCallbackAfterSignOutStaysQuiet() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))
        harness.flow.beginSignIn()
        await harness.waitForSession()
        let state = harness.callbackState(harness.factory.sessions[0])
        await harness.flow.signOut()

        // A browser error page (old state, no tokens) and a stateless malformed callback.
        #expect(await harness.flow.handleCallbackURL(URL(string: "cmux-dev://auth-callback?other=1&cmux_auth_state=\(state)")!) == false)
        #expect(await harness.flow.handleCallbackURL(URL(string: "cmux-dev://auth-callback?other=1")!) == false)
        #expect(harness.flow.lastFailure == nil)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func staleCallbackAfterSignOutAndALaterAttemptStillOffersRetry() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))
        await harness.flow.signOut()
        harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: "previous-launch")) == false)
        #expect(harness.flow.lastFailure == .invalidCallback)
    }

    @Test func replayedCallbackDoesNotReplaceSignedInSessionOrReportFailure() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        let callback = harness.callbackURL(state: harness.callbackState(session))
        session.deliver(callback)
        #expect(await attempt.value)

        #expect(await harness.flow.handleCallbackURL(callback) == false)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.flow.lastFailure == nil)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func rejectedCallbackDoesNotReportFailureOverRestoredSession() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))
        await harness.tokenStore.setTokens(accessToken: "stored-access", refreshToken: "stored-refresh")
        await harness.client.closeUserGate()
        harness.coordinator.start()
        await harness.waitForPendingUserRequest()
        let started = AsyncStream<Void>.makeStream()
        let callback = Task {
            started.continuation.yield(())
            started.continuation.finish()
            return await harness.flow.handleCallbackURL(harness.callbackURL(state: "previous-launch"))
        }
        for await _ in started.stream { break }
        await harness.client.openUserGate()
        await harness.coordinator.awaitBootstrapped()

        #expect(await callback.value == false)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.flow.lastFailure == nil)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "stored-refresh")
        #expect(await harness.tokenStore.getStoredAccessToken() == "stored-access")
    }

    @Test func callbackTokensThatDoNotValidateRecordUnauthorizedFailure() async {
        let harness = HostBrowserSignInFlowHarness(user: nil)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(harness.flow.lastFailure == .unauthorized)
    }

    @Test func callbackValidationDisplayUnsafeErrorRecordsGenericServerFailure() async {
        let harness = HostBrowserSignInFlowHarness(
            user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil)
        )
        await harness.client.setCurrentUserError(StackAuthError(code: "UNEXPECTED", message: "raw server detail"))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(
            harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0]))
        )

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .serverError(0, "auth_failed"))
    }

    @Test func signOutBeforeValidationErrorDoesNotLeaveFailure() async {
        let harness = HostBrowserSignInFlowHarness(
            user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil)
        )
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(
            harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0]))
        )
        await harness.waitForPendingUserRequest()

        await harness.client.setCurrentUserError(AuthError.networkError)
        await harness.flow.signOut()
        await harness.client.openUserGate()

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
        #expect(harness.flow.lastFailure == nil)
    }

    @Test func browserSessionStartFailureRecordsDiagnosticFailure() async {
        let harness = HostBrowserSignInFlowHarness()
        harness.factory.nextStartResult = false

        let result = await harness.flow.signIn(timeout: 60)

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.flow.lastFailure == .browserSignInFailed("start_returned_false"))
    }

    @Test func browserSessionCompletionFailureRecordsDiagnosticFailure() async {
        let harness = HostBrowserSignInFlowHarness()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(.failed(reason: "presentation_context_invalid"))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.flow.lastFailure == .browserSignInFailed("presentation_context_invalid"))
    }

    @Test func abandonedBrowserAttemptTimesOut() async throws {
        let clock = ManualTestClock()
        let harness = HostBrowserSignInFlowHarness(browserAttemptTimeout: 1, clock: clock)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        await clock.waitUntilSleepers(count: 2)

        clock.advance(by: .seconds(1))

        await harness.waitForCondition { harness.flow.isSigningIn == false }
        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .browserSignInFailed("browser_timeout"))
    }

    /// A person who closes the popup (past the instant-cancel window) must see a retry, not a silent return to Sign In.
    @Test func popupClosedByThePersonRecordsARetryableFailure() async {
        let clock = ManualTestClock()
        let harness = HostBrowserSignInFlowHarness(clock: clock)

        let attempt = harness.flow.beginSignIn()
        await harness.waitForSession()
        clock.advance(by: .seconds(5))
        harness.factory.sessions[0].deliver(.cancelled(reason: "canceled_login"))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.flow.lastFailure == .browserSignInFailed("popup_closed"))
    }

    /// A browser handoff that never returns its callback ends after the 5-minute handoff wait with a retryable failure.
    @Test func defaultBrowserHandoffWithoutCallbackEndsWithARetryableTimeout() async {
        let clock = ManualTestClock()
        let harness = HostBrowserSignInFlowHarness(browserAttemptTimeout: 10 * 60, clock: clock)

        let attempt = harness.flow.beginSignIn(inDefaultBrowser: true)
        await harness.waitForCondition { harness.flow.signInIsSlow }
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .seconds(5 * 60))

        #expect(await attempt.value == false)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.openedURLs.count == 1)
        #expect(harness.flow.lastFailure == .browserSignInFailed("browser_timeout"))
    }
}
