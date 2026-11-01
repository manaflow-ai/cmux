@testable import CmuxNextDesign
import Testing

/// The page sizing token must receive the host's complete page zoom, including Agent Chat Zoom.
@MainActor @Suite struct InterfaceScaleScriptTests {
    @Test func scriptPublishesTheEffectivePageZoomAndNotOnlyUIScale() {
        let design = DesignSettings()
        design.uiScale = 1.25
        let script = design.interfaceScaleScript(pageZoom: 1.5625)

        #expect(script.contains("--cmux-ui-scale', '1.5625"))
        #expect(script.contains("cmux-ui-scale-change"))
    }

    @Test func omittedPageZoomUsesUIScale() {
        let design = DesignSettings()
        design.uiScale = 1.25

        #expect(design.interfaceScaleScript().contains("--cmux-ui-scale', '1.25"))
    }
}
