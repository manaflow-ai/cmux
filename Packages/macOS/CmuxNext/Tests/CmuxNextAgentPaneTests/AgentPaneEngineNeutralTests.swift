import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane reaches its page only through the page host's engine-neutral calls
/// (p13-webui-074): it keeps no WebKit view of its own, and the WebKit-only tools (render rate,
/// Web Inspector, the WebContent pid) see a WebKit engine only while WebKit shows the chat. A chat
/// shown in Chromium has a hidden WebKit view that never loads; closing the pane must not load one
/// there (the old close loaded an empty document into it, which starts a WebContent process).
@Suite(.serialized)
@MainActor
struct AgentPaneEngineNeutralTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func chat(_ hosting: FakeChromiumHosting?) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(chromium: hosting), gestures: .testing()))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    private func waitForChromium(_ view: AgentPaneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !view.page.showsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(view.page.showsChromium, "the chat never showed in Chromium")
    }

    @Test func closingAChromiumChatLoadsNothingIntoWebKit() async throws {
        let view = try chat(FakeChromiumHosting())
        try await waitForChromium(view)
        #expect(view.page.webKitView.url == nil, "a Chromium chat loaded its document into WebKit")
        view.close()
        #expect(view.page.webKitView.url == nil, "closing a Chromium chat loaded a document into its unused WebKit view")
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
        #expect(view.page.webKitEngine === view.page.webKitView)
        view.zoom = 1.5
        // One zoom for both engines: the WebKit view shows the page host's.
        #expect(Double(view.page.webKitView.pageZoom) == view.page.pageZoom)
        #expect(view.uiPointerPageZoom == view.page.pageZoom)
        #expect(view.focusTarget === view.page.webKitView)
    }
}
