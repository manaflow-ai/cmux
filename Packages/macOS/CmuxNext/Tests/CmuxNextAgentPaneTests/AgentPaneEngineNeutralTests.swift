import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent pane reaches its page only through the page host's engine-neutral calls:
/// it keeps no WebKit view of its own, and the WebKit-only tools (render rate,
/// Web Inspector, the WebContent pid) see a WebKit engine only while WebKit shows the chat. A chat
/// shown in Chromium has no WebKit view at all: not while Chromium starts, not once
/// it shows, and not when the pane closes (the old close loaded an empty document into a hidden
/// one, which starts a WebContent process).
@Suite(.serialized)
@MainActor
struct AgentPaneEngineNeutralTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func chat(_ hosting: FakeChromiumHosting?) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(chromium: hosting), gestures: .testing()))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    /// The WebKit views in `view`'s subtree.
    private func webKitViews(in view: NSView) -> Int {
        (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webKitViews(in: $1) }
    }

    private func waitForChromium(_ view: AgentPaneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !view.page.showsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(view.page.showsChromium, "the chat never showed in Chromium")
    }

    @Test func aChromiumChatHasNoWebKitView() async throws {
        let view = try chat(FakeChromiumHosting())
        // Chromium does not show the chat yet, so webKitEngine reads the page's WebKit view itself.
        #expect(!view.page.showsChromium)
        #expect(view.page.webKitEngine == nil, "the agent pane built a WebKit view for a Chromium chat")
        #expect(webKitViews(in: view) == 0)
        try await waitForChromium(view)
        #expect(webKitViews(in: view) == 0, "a Chromium chat has a WebKit view after the attach")
        view.close()
        #expect(webKitViews(in: view) == 0, "closing a Chromium chat built a WebKit view")
    }

    @Test func aChromiumChatOffersNoWebKitTools() async throws {
        let view = try chat(FakeChromiumHosting())
        defer { view.close() }
        try await waitForChromium(view)
        #expect(view.page.webKitEngine == nil)
        #expect(view.rendersAtFullRate, "Chromium renders at the display's rate")
        view.rendersAtFullRate = false
        #expect(view.rendersAtFullRate, "a Chromium chat took a WebKit render rate")
        view.zoom = 1.5
        #expect(view.uiPointerPageZoom == view.page.pageZoom)
        #if DEBUG || CMUX_BENCH_HOOKS
        #expect(view.debugPageWebView == nil)
        #expect(view.debugPageZoom == view.page.pageZoom)
        #endif
    }

    @Test func aWebKitChatOffersItsWebKitEngine() throws {
        let view = try chat(nil)
        defer { view.close() }
        let webKit = try #require(view.page.webKitEngine)
        #expect(webKit.isDescendant(of: view))
        view.zoom = 1.5
        // One zoom for both engines: the WebKit view shows the page host's.
        #expect(Double(webKit.pageZoom) == view.page.pageZoom)
        #expect(view.uiPointerPageZoom == view.page.pageZoom)
        #expect(view.focusTarget === webKit)
    }
}
