import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import WebKit

/// A WebKit browser tab renders at the display's full rate, set once when it is made, and nothing
/// rewrites it later (perf-lead row 23). In Low Power Mode WebKit halves every page's rate by itself
/// (`ThrottlingReason::LowPowerMode` in the web process, live, in both directions), so the engine
/// takes no Low Power Mode input: the near-60 preference it once added there held a tab made in
/// Low Power Mode at 30 fps on a 120 Hz display, and its live switch (write the preference, then
/// hide and re-show the tab under a snapshot) did not reach a shown page's cadence: on cmux20
/// (macOS 27, 120 Hz) a page switched to near60 that way still rendered at 120 fps. These read the
/// WebKit preference; the cadence, in and out of Low Power Mode, is
/// `scripts/cmux-next/bench-page-cadence.py`.
@MainActor @Suite(.serialized)
struct WebKitTabRenderRateTests {
    /// Whether `tab` keeps WebKit's near-60 fps rate; fails when this WebKit has no such feature.
    private func rendersNear60(_ tab: WebKitTab) throws -> Bool {
        let near60 = tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature)
        return try #require(near60, "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    @Test func aTabRendersAtTheDisplaysFullRate() throws {
        let tab = WebKitEngine().makeWebKitTab()
        defer { tab.close() }
        #expect(try rendersNear60(tab) == false, "a tab renders near 60 fps: half the rate of a 120 Hz display")
    }

    /// A page-opened window gets the opener's configuration from WebKit; the engine still sets it
    /// to full rate before the tab is made.
    @Test func aTabOpenedByAPageRendersAtTheDisplaysFullRate() throws {
        let opened = WKWebViewConfiguration()
        WebKitRenderRate.apply(fullRate: false, to: opened.preferences)
        let tab = WebKitEngine().makeWebKitTab(webViewConfiguration: opened)
        defer { tab.close() }
        #expect(try rendersNear60(tab) == false, "a page-opened tab kept the near-60 rate it was handed")
    }
}
