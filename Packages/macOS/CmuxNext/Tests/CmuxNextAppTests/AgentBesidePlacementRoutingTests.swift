@testable import CmuxNextApp
import Testing

@Suite("Agent beside right pane routing")
struct AgentBesidePlacementRoutingTests {
    @Test func existingRightAreaInsertsAfterItsActiveTab() {
        #expect(AgentBesidePlacement.insertionIndex(active: "docs-1", tabs: ["docs-0", "docs-1", "docs-2"]) == 2)
    }

    @Test func missingActiveTabAppendsWithoutReorderingExistingTabs() {
        #expect(AgentBesidePlacement.insertionIndex(active: "closed", tabs: ["docs-0", "docs-1"]) == 2)
    }

    @Test func sessionInfoAndTranscriptIdentitySelectTheSameRightTab() {
        let docs = RightPanePlacement.Area(tabs: [.init(id: "pr:https://github.com/manaflow-ai/cmux/pull/1")], active: "pr:https://github.com/manaflow-ai/cmux/pull/1")
        let fromSessionInfo = RightPanePlacement.decide(kind: .documents, identity: "pr:https://github.com/manaflow-ai/cmux/pull/1", chatWidth: 720, rightColumnWidth: 520, documents: docs)
        let fromTranscript = RightPanePlacement.decide(kind: .documents, identity: "pr:https://github.com/manaflow-ai/cmux/pull/1", chatWidth: 720, rightColumnWidth: 520, documents: docs)
        #expect(fromSessionInfo == .selectExisting("pr:https://github.com/manaflow-ai/cmux/pull/1"))
        #expect(fromTranscript == fromSessionInfo)
    }
}
