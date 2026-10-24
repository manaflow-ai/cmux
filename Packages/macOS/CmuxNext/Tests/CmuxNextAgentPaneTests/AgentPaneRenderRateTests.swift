import AppKit
import CmuxNextDesign
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent chat's render rate is fixed when its page is made, as every other cmux page's and
/// browser tab's is (perf-lead row 23).
///
/// The chat used to change its rate live: after a settled scroll the page's adaptive policy sent
/// `pane.renderRate {full}` and the pane wrote WebKit's near-60 preference, then hid the web view
/// for 33 ms under a snapshot so WebKit would read it. On cmux20 (macOS 27, 120 Hz) a page shown
/// again that way kept its old cadence, so each switch cost a snapshot readback, a hide and show
/// and a focus hand-off for no rate change, and the stale preference took effect at the next real
/// visibility change (a tab switch): the chat could stay at 60 fps on a 120 Hz display while the
/// policy believed it was at full rate. In Low Power Mode WebKit halves every page by itself.
@Suite(.serialized)
@MainActor
struct AgentPaneRenderRateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private let directory: URL
    private let file: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "agent-rate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
    }

    /// Whether `view`'s page keeps WebKit's near-60 fps rate. It fails, rather than answering, when
    /// this WebKit lists no such feature: then no rate this code sets has any effect either.
    private func rendersNear60(_ view: AgentPaneView) throws -> Bool {
        let near60 = view.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature)
        return try #require(near60, "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    /// The pane's own WebKit host and the shared page host both make the chat at full rate unless
    /// asked for the capped rate.
    @Test(arguments: [false, true])
    func aChatMadeWithTheDefaultRateRendersAtTheDisplaysFullRate(pageHost: Bool) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: pageHost, chromium: nil))
        defer { view.close() }
        #expect(try rendersNear60(view) == false, "the chat renders near 60 fps: half the rate of a 120 Hz display")
        #expect(view.rendersAtFullRate)
    }

    @Test func aChatMadeAtTheCappedRateKeepsIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), renderRate: .capped))
        defer { view.close() }
        #expect(try rendersNear60(view))
        #expect(view.rendersAtFullRate == false)
    }

    /// The page has no request that changes the rate live: the old `pane.renderRate` and its
    /// `pane.framePacing` read are unknown methods, and answering one leaves the page shown, at
    /// the rate it was made with, with nothing laid over it.
    @Test func thePageCannotChangeTheChatsRateLive() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AgentPaneModel(host: NoHost())
        let view = try #require(AgentPaneView(model: model, source: .bundled(file)))
        defer { view.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.addSubview(view)
        view.frame = host.bounds
        view.layoutSubtreeIfNeeded()
        let before = try rendersNear60(view)
        let covers = view.webView.superview?.subviews.count

        let rate = AgentPaneRequest(body: ["method": "pane.renderRate", "params": ["full": false]])
        #expect(rate == .unsupported("pane.renderRate"))
        let pacing = AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": [8.3, 16.7]]])
        #expect(pacing == .unsupported("pane.framePacing"))
        #expect(AgentPageOps.methods["pane.renderRate"] == nil)
        #expect(AgentPageOps.methods["pane.framePacing"] == nil)

        _ = await model.respond(to: rate)
        _ = await model.respond(to: pacing)
        #expect(view.webView.isHidden == false, "answering the page hid the chat")
        #expect(view.webView.superview?.subviews.count == covers, "answering the page laid a snapshot over the chat")
        #expect(try rendersNear60(view) == before)
    }
}
