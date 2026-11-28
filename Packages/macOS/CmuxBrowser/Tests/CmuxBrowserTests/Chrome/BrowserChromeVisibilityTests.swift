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
