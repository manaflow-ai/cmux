@testable import CmuxNextBrowser
import Testing

/// The UI pointer prototype is an explicit Debug Settings opt-in. Its normal
/// browser path stays unchanged until a developer enables the toggle.
@Suite struct BrowserPageTunablesTests {
    @Test func uiPointerIsOffByDefault() {
        #expect(BrowserPageTunables.uiPointer.defaultValue == false)
        #expect(BrowserPageTunables.uiPointer.descriptor.key == "browserPage.uiPointer")
    }

    @Test func disabledPickerStillLetsAnActiveModeTurnOff() {
        let state = BrowserToolbarPolicy.state(
            .designMode,
            BrowserToolbarFacts(engine: .webkit, hostsDevTools: true, designMode: true)
        )
        #expect(state.isEnabled, "an active picker must remain dismissible if the Debug toggle is turned off")
    }
}
