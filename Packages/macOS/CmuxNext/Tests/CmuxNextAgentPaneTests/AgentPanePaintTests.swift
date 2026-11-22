import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page reports its first frame (`pane.painted`); until then the pane
/// keeps what it showed (#17485, New Tab blank).
@MainActor
@Suite struct AgentPanePaintTests {
    @Test func thePageReportsItsFirstFrame() {
        #expect(AgentPaneRequest(body: ["method": "pane.painted"]) == .painted)
        #expect(AgentPageOps.all.contains("cmux.agent.pane.painted"))
    }

    @Test func waitersRunOnceWhenThePagePaints() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        var runs = 0
        model.whenPainted { runs += 1 }
        #expect(!model.hasPainted && runs == 0)
        _ = await model.respond(to: .painted)
        _ = await model.respond(to: .painted)
        #expect(model.hasPainted && runs == 1)
        // A pane that already painted runs a new waiter at once.
        model.whenPainted { runs += 1 }
        #expect(runs == 2)
    }

    @Test func paintingDoesNotTouchTheNewTabPage() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        _ = await model.respond(to: .painted)
        #expect(model.userTouched == false)
    }
}
