import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// A sign-in that runs in the default browser from the start: no popup, the
/// hosted page opens there, and its `<scheme>://auth-callback` signs the app in.
/// macOS hands an `ASWebAuthenticationSession` to the default browser only when
/// that browser supports it; with one that does not (Edge, seen 2026-10-19), the
/// popup ends as `canceledLogin` every time and nothing signs in.
@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowDefaultBrowserTests {
    private func state(of url: URL?) -> String {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "cmux_auth_state" }?.value ?? ""
    }

    @Test func aDefaultBrowserSignInOpensThePageAndItsCallbackSignsIn() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let attempt = harness.flow.beginSignIn(inDefaultBrowser: true)
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }

        #expect(harness.factory.sessions.isEmpty)
        #expect(harness.openedURLs.count == 1)
        #expect(harness.flow.isSigningIn)
        #expect(harness.flow.isPresentingSignIn)
        let callbackState = state(of: harness.openedURLs.first)
        #expect(!callbackState.isEmpty)

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState)))
        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(!harness.flow.isSigningIn && !harness.flow.isPresentingSignIn)
    }

    @Test func cancellingADefaultBrowserSignInRejectsItsLateCallback() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))

        let attempt = harness.flow.beginSignIn(inDefaultBrowser: true)
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }
        let callbackState = state(of: harness.openedURLs.first)

        harness.flow.cancelSignIn()

        #expect(await attempt.value == false)
        #expect(!harness.flow.isSigningIn && !harness.flow.isPresentingSignIn)
        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState)) == false)
        #expect(!harness.coordinator.isAuthenticated)
    }

    /// Cancel after the callback arrived: its tokens already replaced the
    /// session, so the sign-in finishes rather than half-tearing down.
    @Test func cancelAfterTheCallbackArrivedLetsTheSignInFinish() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        await harness.client.closeUserGate()

        let attempt = harness.flow.beginSignIn(inDefaultBrowser: true)
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }
        let callbackState = state(of: harness.openedURLs.first)
        let callback = Task { await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState)) }
        await harness.waitForPendingUserRequest()

        harness.flow.cancelSignIn()
        #expect(harness.flow.isSigningIn)
        await harness.client.openUserGate()

        #expect(await callback.value)
        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(!harness.flow.isSigningIn && !harness.flow.isPresentingSignIn)
    }

    @Test func aDefaultBrowserThatCannotOpenEndsTheAttemptWithAFailure() async {
        let harness = HostBrowserSignInFlowHarness(openSucceeds: false)

        let attempt = harness.flow.beginSignIn(inDefaultBrowser: true)

        #expect(await attempt.value == false)
        #expect(harness.factory.sessions.isEmpty)
        #expect(harness.openedURLs.count == 1)
        #expect(harness.flow.lastFailure == .browserSignInFailed("browser_open_failed"))
    }
}
