import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-27: "i also added that cool opening new tab it just preserves the composer look from before oh but then it just flickers afterwards it seems which defeats the purpose"
/// The first pane paint may still be the lazy New Tab screen's null fallback. Native reveal and
/// spare snapshot waiters must stay held until the screen itself has rendered.
@Suite(.serialized)
@MainActor
struct AgentPaneNewTabPaintTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            throw AgentPaneHostError.daemonStopped
        }
    }

    @Test func emptyLazyFramesNeverReleaseThePreservedComposer() async {
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        var released = 0
        var reports = 0
        model.whenPainted { released += 1 }
        model.onPaintReport = { reports += 1 }

        for _ in 0..<3 {
            _ = await model.respond(to: AgentPaneRequest(body: [
                "method": "pane.painted", "params": ["newTabDrawn": false],
            ]))
        }
        #expect(!model.hasPainted)
        #expect(!model.pageReportedPaint)
        #expect(released == 0)
        #expect(reports == 0)

        _ = await model.respond(to: AgentPaneRequest(body: [
            "method": "pane.painted", "params": ["newTabDrawn": true],
        ]))
        #expect(model.hasPainted)
        #expect(model.pageReportedPaint)
        #expect(released == 1)
        #expect(reports == 1)

        // An older asynchronous callback cannot regress the accepted frame or notify cover owners.
        _ = await model.respond(to: AgentPaneRequest(body: [
            "method": "pane.painted", "params": ["newTabDrawn": false],
        ]))
        #expect(model.hasPainted)
        #expect(released == 1)
        #expect(reports == 1)
    }

    @Test func legacyPagesAndChatsKeepTheirPaintContract() async {
        for newTab in [AgentPaneNewTab(kind: .agent), nil] {
            let model = AgentPaneModel(host: NoHost(), newTab: newTab)
            _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
            #expect(model.hasPainted)
        }
    }
}
