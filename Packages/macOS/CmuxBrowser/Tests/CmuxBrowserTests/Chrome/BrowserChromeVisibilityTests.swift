import Foundation
import Testing
@testable import CmuxBrowser

struct BrowserChromeVisibilityTests {
    @Test("Legacy omnibar visibility maps to revealable chrome states")
    func legacyOmnibarVisibilityMapping() {
        #expect(BrowserChromeVisibility(omnibarVisible: true) == .visible)
        #expect(BrowserChromeVisibility(omnibarVisible: false) == .hidden)
    }

    @Test("Chromeless browser policy disables user chrome actions")
    func chromelessPolicy() {
        #expect(!BrowserChromeVisibility.chromeless.isOmnibarVisible)
        #expect(!BrowserChromeVisibility.chromeless.allowsAddressBarFocus)
        #expect(!BrowserChromeVisibility.chromeless.allowsOmnibarToggle)
        #expect(BrowserChromeVisibility.hidden.allowsAddressBarFocus)
        #expect(BrowserChromeVisibility.hidden.allowsOmnibarToggle)
    }

    @Test("Chrome policy round-trips through persisted raw values")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(
            BrowserChromeVisibility.chromeless
        )
        let decoded = try JSONDecoder().decode(
            BrowserChromeVisibility.self,
            from: encoded
        )

        #expect(decoded == .chromeless)
    }
}

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
