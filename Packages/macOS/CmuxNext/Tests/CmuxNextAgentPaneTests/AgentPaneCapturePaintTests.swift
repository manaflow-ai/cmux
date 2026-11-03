#if DEBUG
import CmuxNextPagesTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

@MainActor
struct AgentPaneCapturePaintTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            throw AgentPaneHostError.daemonStopped
        }
    }

    @Test func aLoadingCoverGivingUpDoesNotCountAsDocumentPaint() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: FakeChromiumHosting()))
        let page = try #require(view.page)
        #expect(!page.hasPainted)

        // The cover may give up while Chromium is still starting. The document has not painted.
        view.model.markPainted()
        #expect(view.model.hasPainted)
        #expect(!view.debugPageHasPainted)

        page.notePainted()
        #expect(view.debugPageHasPainted)
    }

    @Test func theLegacyWebKitHostUsesItsPanePaintSignal() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: false, chromium: nil))
        #expect(!view.debugPageHasPainted)
        view.model.markPainted()
        #expect(view.debugPageHasPainted)
    }

    @Test func documentPaintStillWaitsForTheAgentContent() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: FakeChromiumHosting()))
        let page = try #require(view.page)
        page.notePainted()
        #expect(!view.debugPageHasPainted)
        view.model.markPainted()
        #expect(view.debugPageHasPainted)
    }
}
#endif
