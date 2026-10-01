import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneRenderingTests {
    private let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-rendering-test.html")
    private let key = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// WebKit renders a page at the display-rate divisor nearest 60 fps
    /// (80 Hz on a 160 Hz display). The pane can opt out to measure the full
    /// rate; it keeps WebKit's default until a frame's paint fits.
    @Test func thePaneRendersAtTheFullDisplayRateOnlyWhenAsked() throws {
        let full = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page), rendersAtFullRate: true))
        defer { full.close() }
        let standard = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { standard.close() }
        // A WebKit without the feature has no 60 fps preference to lift.
        guard let near60 = full.webView.configuration.preferences.isWebKitFeatureEnabled(key) else { return }
        #expect(near60 == false)
        #expect(standard.webView.configuration.preferences.isWebKitFeatureEnabled(key) == true)
    }

    @Test func anUnknownFeatureIsLeftAlone() {
        let preferences = WKPreferences()
        #expect(preferences.isWebKitFeatureEnabled("NoSuchCmuxFeature") == nil)
        #expect(!preferences.setWebKitFeature("NoSuchCmuxFeature", enabled: true))
    }
}
