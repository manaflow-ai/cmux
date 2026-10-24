import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import WebKit

/// A WebKit browser tab renders at the display's full rate whatever Low Power Mode says when it is
/// made, and a Low Power Mode change leaves an open tab alone (perf-lead row 23). In Low Power Mode
/// WebKit halves every page's rate by itself (`ThrottlingReason::LowPowerMode` in the web process,
/// live, in both directions), so the near-60 preference on top of it held a tab made in Low Power
/// Mode at 30 fps on a 120 Hz display, and the live switch (write the preference, then hide and
/// re-show the tab under a snapshot) did not reach a shown page's cadence: on cmux20 (macOS 27,
/// 120 Hz) a page switched to near60 that way still rendered at 120 fps. These read the WebKit
/// preference and the view; the cadence is `scripts/cmux-next/bench-page-cadence.py`.
@MainActor @Suite(.serialized)
struct WebKitTabRenderRateTests {
    /// Whether `tab` keeps WebKit's near-60 fps rate; fails when this WebKit has no such feature.
    private func rendersNear60(_ tab: WebKitTab) throws -> Bool {
        let near60 = tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature)
        return try #require(near60, "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    @Test func aTabMadeInLowPowerModeRendersAtTheDisplaysFullRate() throws {
        let engine = WebKitEngine(lowPowerMode: LowPowerMode(enabled: true))
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(try rendersNear60(tab) == false,
                "a tab made in Low Power Mode renders near 60 fps, which WebKit's own Low Power Mode throttling halves again")
    }

    @Test func aLowPowerModeChangeLeavesAShownTabAlone() throws {
        let lowPowerMode = LowPowerMode(enabled: false)
        let engine = WebKitEngine(lowPowerMode: lowPowerMode)
        let tab = engine.makeWebKitTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            tab.close()
            window.close()
        }
        window.contentView?.addSubview(tab.webView)
        lowPowerMode.override = true
        #expect(try rendersNear60(tab) == false, "a Low Power Mode change rewrote an open tab's rate")
        lowPowerMode.override = false
        #expect(try rendersNear60(tab) == false)
    }
}
