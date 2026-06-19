import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct HostBrowserSignInFlowFailureTests {
    @Test func invalidCallbackPayloadIsRejected() async {
        let harness = makeHostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForHostBrowserSession(harness.factory)
        harness.factory.sessions[0].deliver(URL(string: "cmux-dev://auth-callback?other=1&cmux_auth_state=\(hostBrowserCallbackState(harness.factory.sessions[0]))")!)

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(harness.flow.lastFailure == .invalidCallback)
    }

    @Test func externalCallbackStateMismatchRecordsInvalidCallbackFailure() async {
        let harness = makeHostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForHostBrowserSession(harness.factory)

        let result = await harness.flow.handleCallbackURL(hostBrowserCallbackURL(state: "other-state"))

        #expect(result == false)
        #expect(harness.flow.isSigningIn)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .invalidCallback)

        harness.factory.sessions[0].cancel()
        #expect(await attempt.value == false)
    }

    @Test func callbackTokensThatDoNotValidateRecordUnauthorizedFailure() async {
        let harness = makeHostBrowserSignInFlowHarness(user: nil)

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await waitForHostBrowserSession(harness.factory)
        harness.factory.sessions[0].deliver(hostBrowserCallbackURL(state: hostBrowserCallbackState(harness.factory.sessions[0])))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(harness.flow.lastFailure == .unauthorized)
    }

    @Test func abandonedBrowserAttemptTimesOut() async throws {
        let clock = ManualTestClock()
        let harness = makeHostBrowserSignInFlowHarness(browserAttemptTimeout: 1, clock: clock)

        harness.flow.beginSignIn()
        await waitForHostBrowserSession(harness.factory)
        await clock.waitUntilSleepers(count: 2)

        clock.advance(by: .seconds(1))

        await waitForHostBrowserCondition { harness.flow.isSigningIn == false }
        #expect(harness.factory.sessions[0].cancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .timedOut)
    }
}
