import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent page's engine follows the value the app passes for feature `agentChromium`,
/// never the Debug tunable `agent.chromium` it replaced: off keeps a new
/// page on the page host's WebKit even where Chromium serves it.
@Suite(.serialized)
@MainActor
struct AgentPaneChromiumFeatureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func chat(_ hosting: FakeChromiumHosting, chromiumChat: Bool) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(chromium: hosting), gestures: .testing(), chromiumChat: chromiumChat))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    @Test func theFeatureOffKeepsTheChatOnWebKit() throws {
        let hosting = FakeChromiumHosting()
        let view = try chat(hosting, chromiumChat: false)
        defer { view.close() }
        #expect(view.page.webKitEngine != nil, "the chat did not open in WebKit with agentChromium off")
        #expect(hosting.made.isEmpty, "Chromium made a page with agentChromium off")
        #expect(AgentPaneView.newPagesShowInWebKit(chromiumChat: false, hosting: hosting))
    }

    @Test func theFeatureOnOpensTheChatInChromium() throws {
        let hosting = FakeChromiumHosting()
        let view = try chat(hosting, chromiumChat: true)
        defer { view.close() }
        #expect(view.page.webKitEngine == nil, "the chat opened in WebKit with agentChromium on")
        #expect(!AgentPaneView.newPagesShowInWebKit(chromiumChat: true, hosting: hosting))
    }
}
