import AppKit
import CmuxNextAgentActivity
import CmuxNextDesign
import Testing
import WebKit

/// The Activity fallback view (shown when the page host has no Activity root) follows Low Power
/// Mode as cmux pages and browser tabs do: full rate outside it, near 60 fps inside it, applied
/// live when it changes. It used to read the app-wide observer once at creation, so a view made
/// outside Low Power Mode stayed at full rate inside it, and one made inside stayed near 60 after.
@MainActor
struct AgentActivityRenderRateTests {
    /// Whether `view` keeps WebKit's near-60 fps rate; fails when this WebKit has no such feature.
    private func rendersNear60(_ view: AgentActivityHostView) throws -> Bool {
        try #require(view.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    @Test func theFallbackViewFollowsLowPowerMode() throws {
        let source = AgentActivityMockSource()
        let lowPowerMode = LowPowerMode(enabled: false)
        let view = AgentActivityHostView(model: AgentActivityModel(source: source), source: source, lowPowerMode: lowPowerMode)
        #expect(try rendersNear60(view) == false)
        lowPowerMode.override = true
        #expect(try rendersNear60(view))
        lowPowerMode.override = false
        #expect(try rendersNear60(view) == false)
    }
}
