@testable import CmuxNextBrowser
import Testing

/// The UI pointer prototype is an explicit Debug Settings opt-in. Its normal
/// browser path stays unchanged until a developer enables the toggle.
@Suite struct BrowserPageTunablesTests {
    @Test func uiPointerIsOffByDefault() {
        #expect(BrowserPageTunables.uiPointer.defaultValue == false)
        #expect(BrowserPageTunables.uiPointer.descriptor.key == "browserPage.uiPointer")
    }
}
