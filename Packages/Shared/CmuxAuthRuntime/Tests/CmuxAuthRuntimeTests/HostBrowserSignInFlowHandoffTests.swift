import AuthenticationServices
import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Behavior tests for default-browser continuation after hosted-browser handoff.
@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowHandoffTests {
    @Test func nonAuthBrowserCompletionContinuesAttemptInDefaultBrowserAndAcceptsLateCallback() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let callbackState = harness.callbackState(harness.factory.sessions[0])

        harness.factory.sessions[0].deliver(URL(string: "https://example.test/handler/sign-in?after_auth_return_to=1")!)
        // Deadline-bounded graceful wait: on a regression the assertions below
        // fail instead of aborting the whole test process.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while harness.openedURLs.isEmpty, clock.now < deadline {
            await Task.yield()
        }

        #expect(harness.openedURLs == [
            URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\(callbackState)")!
        ])
        #expect(harness.flow.isSigningIn)
        #expect(harness.flow.isPresentingSignIn)
        #expect(harness.flow.signInIsSlow)
        #expect(harness.factory.sessions.count == 1)

        harness.flow.beginSignIn()
        await Task.yield()

        #expect(harness.factory.sessions.count == 1)
        #expect(harness.openedURLs.count == 1)

        let callbackResult = await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState))

        #expect(callbackResult)
        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser == user)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
        #expect(!harness.flow.isSigningIn && !harness.flow.isPresentingSignIn)
    }

    @Test func handoffOpenFailureEndsAttemptAndAllowsRetry() async {
        // The default browser fails to launch on the handed-off attempt.
        let harness = HostBrowserSignInFlowHarness(openSucceeds: false)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()

        harness.factory.sessions[0].deliver(URL(string: "https://example.test/handler/sign-in?after_auth_return_to=1")!)

        // The open was attempted once but failed, so the attempt ends promptly
        // with a failure instead of parking the awaited sign-in until timeout.
        #expect(await attempt.value == false)
        #expect(harness.openedURLs.count == 1)
        #expect(!harness.flow.isSigningIn)
        #expect(!harness.flow.isPresentingSignIn)
        #expect(harness.flow.lastFailure != nil)

        // A fresh sign-in click starts a brand-new attempt.
        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)
        #expect(harness.factory.sessions.count == 2)
    }

    @Test func staleNonAuthCompletionDoesNotOpenBrowser() async {
        let harness = HostBrowserSignInFlowHarness()

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let staleSession = harness.factory.sessions[0]
        staleSession.deliverCancelCompletion = false

        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)
        staleSession.deliver(URL(string: "https://example.test/handler/sign-in?after_auth_return_to=1")!)
        await Task.yield()

        #expect(harness.openedURLs.isEmpty)
        #expect(harness.factory.sessions.count == 2)
    }
}
