@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import WebKit

/// The App pushes Low Power Mode from its energy monitor into `WebKitEngine.lowPowerMode`
/// (p14-energy-021): open tabs and new tabs take the rate for it, near 60 fps in Low Power Mode.
/// Off screen, so no tab re-shows under a snapshot; the rate is set on its preferences.
@MainActor @Suite(.serialized) struct WebKitLowPowerModeTests {
    static func near60(_ tab: WebKitTab) throws -> Bool {
        try #require(tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "this WebKit has no \(WebKitRenderRate.near60FPSFeature) feature")
    }

    @Test func anOpenTabFollowsThePushedLowPowerMode() throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(try !Self.near60(tab), "a tab opened on full power renders near 60 fps")
        engine.lowPowerMode = true
        #expect(try Self.near60(tab), "the open tab kept the full rate in Low Power Mode")
        engine.lowPowerMode = false
        #expect(try !Self.near60(tab), "the open tab stayed near 60 fps after Low Power Mode ended")
    }

    @Test func aNewTabStartsAtTheRateForThePushedValue() throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), lowPowerMode: true)
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(try Self.near60(tab))
    }
}
