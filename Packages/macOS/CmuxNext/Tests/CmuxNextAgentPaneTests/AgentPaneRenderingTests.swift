import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneRenderingTests {
    private let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-rendering-test.html")
    private let key = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// WebKit renders a page at the display-rate divisor nearest 60 fps
    /// (80 Hz on a 160 Hz display). The pane can opt out to render at the
    /// full rate; by default it keeps WebKit's rate.
    @Test func thePaneRendersAtTheFullDisplayRateOnlyWhenAsked() throws {
        let full = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page), renderRate: .full))
        defer { full.close() }
        let standard = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { standard.close() }
        // A WebKit without the feature has no 60 fps preference to lift.
        guard let near60 = full.webView.configuration.preferences.isWebKitFeatureEnabled(key) else { return }
        #expect(near60 == false)
        #expect(standard.webView.configuration.preferences.isWebKitFeatureEnabled(key) == true)
    }

    /// An adaptive pane starts at full rate, caps it after a scroll that
    /// misses frames, and leaves a fixed-rate pane alone.
    @Test func anAdaptivePaneCapsItsRateAfterAScrollThatMissesFrames() async throws {
        let adaptive = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page), renderRate: .adaptive))
        defer { adaptive.close() }
        let full = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page), renderRate: .full))
        defer { full.close() }
        guard adaptive.webView.configuration.preferences.isWebKitFeatureEnabled(key) != nil else { return }
        adaptive.displayFramesPerSecond = { 160 }
        full.displayFramesPerSecond = { 160 }
        #expect(adaptive.rendersAtFullRate)
        let missed = Array(repeating: 12.5, count: 120)
        _ = await adaptive.model.respond(to: .framePacing(missed))
        _ = await full.model.respond(to: .framePacing(missed))
        #expect(!adaptive.rendersAtFullRate)
        #expect(full.rendersAtFullRate)
    }

    /// WebKit reads the rate only when the page's visibility changes, so
    /// setting it on a live page did nothing until the pane was hidden and
    /// shown. The pane now re-shows the web view itself, under a snapshot
    /// of the page so nothing visibly blinks.
    @Test func aLiveRateChangeReShowsThePageUnderASnapshot() async throws {
        let pane = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { pane.close() }
        guard pane.webView.configuration.preferences.isWebKitFeatureEnabled(key) != nil else { return }
        pane.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        pane.snapshotPage = { NSImage(size: NSSize(width: 400, height: 300)) }
        var steps: [(hidden: Bool, covered: Bool)] = []
        pane.pause = { [unowned pane] _ in
            steps.append((pane.webView.isHidden, pane.subviews.contains { $0 is NSImageView }))
        }
        pane.rendersAtFullRate = true
        await pane.rateReapply?.value
        #expect(steps.first?.hidden == true)
        let coveredThroughout = steps.allSatisfy { $0.covered }
        #expect(coveredThroughout)
        #expect(!pane.webView.isHidden)
        #expect(!pane.subviews.contains { $0 is NSImageView })
        // Setting the rate it already has changes nothing.
        steps = []
        pane.rendersAtFullRate = true
        await pane.rateReapply?.value
        #expect(steps.isEmpty)
    }

    @Test func anUnknownFeatureIsLeftAlone() {
        let preferences = WKPreferences()
        #expect(preferences.isWebKitFeatureEnabled("NoSuchCmuxFeature") == nil)
        #expect(!preferences.setWebKitFeature("NoSuchCmuxFeature", enabled: true))
    }
}
