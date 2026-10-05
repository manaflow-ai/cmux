import WebKit
import Testing
@testable import CmuxNextBrowser
import CmuxNextDesign

/// Browser tabs render at the display's full rate (120 Hz on ProMotion),
/// as the agent pane and React pages already do; Low Power Mode keeps
/// WebKit's rate nearest 60 fps.
@MainActor
@Suite(.serialized)
struct WebKitFrameRateTests {
    @Test func browserTabsRenderAtFullRateUnlessLowPower() {
        let engine = WebKitEngine()
        engine.lowPowerMode = { false }
        let tab = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        #expect(tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature) == false)
        engine.lowPowerMode = { true }
        let saving = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        #expect(saving.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature) != false)
        tab.close()
        saving.close()
    }
}
