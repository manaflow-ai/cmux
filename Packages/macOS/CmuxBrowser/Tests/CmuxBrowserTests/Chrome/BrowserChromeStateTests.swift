import Testing
@testable import CmuxBrowser

@MainActor
struct BrowserChromeStateTests {
    @Test("Chrome state publishes revealable visibility transitions")
    func revealableVisibilityTransitions() {
        let state = BrowserChromeState(visibility: .hidden)

        #expect(!state.isOmnibarVisible)
        #expect(state.setOmnibarVisible(true))
        #expect(state.visibility == .visible)
        #expect(state.toggleOmnibarVisibility() == false)
        #expect(state.visibility == .hidden)
    }

    @Test("Chromeless state rejects user visibility changes")
    func chromelessPolicyRejectsUserChanges() {
        let state = BrowserChromeState(visibility: .chromeless)

        #expect(!state.setOmnibarVisible(true))
        #expect(!state.toggleOmnibarVisibility())
        #expect(state.visibility == .chromeless)
    }

    @Test("Policy restoration can replace a chromeless state")
    func policyRestorationReplacesChromelessState() {
        let state = BrowserChromeState(visibility: .chromeless)

        #expect(state.setVisibility(.visible))
        #expect(state.isOmnibarVisible)
    }

    @Test("Content fullscreen hides the chrome without changing the policy")
    func contentFullscreenHidesChromeOnly() {
        let state = BrowserChromeState(visibility: .visible)

        #expect(state.setContentFullscreen(true))
        #expect(!state.setContentFullscreen(true))
        #expect(!state.isOmnibarVisible)
        #expect(state.visibility == .visible)
        // A toggle while fullscreen acts on the policy, not on the hidden chrome.
        #expect(state.toggleOmnibarVisibility() == false)
        #expect(state.visibility == .hidden)
        #expect(state.toggleOmnibarVisibility())
        #expect(state.setContentFullscreen(false))
        #expect(state.isOmnibarVisible)
    }
}
