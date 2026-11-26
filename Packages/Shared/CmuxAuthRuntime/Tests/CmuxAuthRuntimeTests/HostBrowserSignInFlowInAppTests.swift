import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// A sign-in the app opens in its own browser tab: the hosted page opens there
/// (passkeys and the emailed code work in it), and its `<scheme>://auth-callback`
/// comes back in-process. The callback still has to carry the attempt's state.
@MainActor
private final class TabRecorder { var urls: [URL] = [] }

@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowInAppTests {
    private func state(of url: URL?) -> String {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "cmux_auth_state" }?.value ?? ""
    }

    @Test func anInAppSignInOpensTheTabAndItsCallbackSignsIn() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        let tabs = TabRecorder()

        let attempt = harness.flow.beginSignIn(openingWith: { tabs.urls.append($0); return true })
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }

        #expect(harness.factory.sessions.isEmpty)
        #expect(harness.openedURLs.isEmpty)
        #expect(tabs.urls.count == 1)
        let callbackState = state(of: tabs.urls.first)
        #expect(!callbackState.isEmpty)

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState)))
        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
    }

    @Test func anInAppCallbackWithAnotherStateIsRejected() async {
        let harness = HostBrowserSignInFlowHarness(user: CMUXAuthUser(id: "u1", primaryEmail: nil, displayName: nil))
        let tabs = TabRecorder()

        _ = harness.flow.beginSignIn(openingWith: { tabs.urls.append($0); return true })
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: "not-the-attempts-state")) == false)
        #expect(!harness.coordinator.isAuthenticated)
        harness.flow.cancelSignIn()
    }

    /// No window to open a tab in: the page opens in the default browser instead.
    @Test func aTabThatCannotOpenFallsBackToTheDefaultBrowser() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let attempt = harness.flow.beginSignIn(openingWith: { _ in false })
        await harness.waitForCondition { harness.flow.signInIsSlow || !harness.flow.isSigningIn }

        #expect(harness.openedURLs.count == 1)
        let callbackState = state(of: harness.openedURLs.first)
        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: callbackState)))
        #expect(await attempt.value)
    }
}
