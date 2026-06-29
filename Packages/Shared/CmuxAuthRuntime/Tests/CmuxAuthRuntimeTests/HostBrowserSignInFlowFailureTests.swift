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
        await harness.client.setCurrentUserError(StackAuthError(code: "RATE_LIMIT", message: "try later"))

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
        #expect(harness.flow.lastFailure == .timedOut)
    }
}
