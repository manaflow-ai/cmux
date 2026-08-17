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
}
