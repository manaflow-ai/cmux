import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneRenderingTests {
    /// WebKit renders a page at the display-rate divisor nearest 60 fps, so
    /// on a 160 Hz display the transcript scrolled at 80 Hz while native
    /// views scroll at 160.
    @Test func thePaneRendersAtTheFullDisplayRate() throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-rendering-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { view.close() }
        let key = "PreferPageRenderingUpdatesNear60FPSEnabled"
        // A WebKit without the feature has no 60 fps preference to lift.
        guard let near60 = view.webView.configuration.preferences.isWebKitFeatureEnabled(key) else { return }
        #expect(near60 == false)
    }

    @Test func anUnknownFeatureIsLeftAlone() {
        let preferences = WKPreferences()
        #expect(preferences.isWebKitFeatureEnabled("NoSuchCmuxFeature") == nil)
        #expect(!preferences.setWebKitFeature("NoSuchCmuxFeature", enabled: true))
    }
}
