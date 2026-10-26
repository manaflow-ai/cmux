import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// p13-webui-009: an agent pane on the page host opens its page through the host it is given (the
/// app's `AppServices.webUI`), not the static `PageWebView.chromiumHosting`, so the host knows the
/// page and its Chromium host makes it.
@Suite(.serialized)
@MainActor
struct AgentPaneWebUIHostTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func thePageOpensThroughTheGivenHost() throws {
        let file = try #require(AgentPageTestRoot.page)
        let host = WebUIHost.agentPaneTestHost()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: host, gestures: .testing()))
        let page = try #require(view.page)
        #expect(host.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(page)])
        #expect(host.registry.pages(id: PageDescriptor.agent.id).contains { $0 === page })
        // The host's own registry, not the process-wide one the static forwarders fill.
        #expect(!PageRegistry.pages(id: PageDescriptor.agent.id).contains { $0 === page })
        host.close(page)
    }

    /// The engine is picked with the given host's Chromium: with none the chat stays on WebKit.
    @Test func theHostsChromiumPicksTheEngine() throws {
        let file = try #require(AgentPageTestRoot.page)
        let chromium = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                                  pageHost: .agentPaneTestHost(chromium: FakeChromiumHosting()), gestures: .testing()))
        let chromiumPage = try #require(chromium.page)
        #expect(chromiumPage.engineDecision == .chromium)
        let webKit = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                                pageHost: .agentPaneTestHost(), gestures: .testing()))
        let webKitPage = try #require(webKit.page)
        #expect(webKitPage.engineDecision != .chromium)
    }

    @Test func noHostKeepsThePaneOnItsOwnWebKitHost() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), gestures: .testing()))
        #expect(view.page == nil)
    }
}
