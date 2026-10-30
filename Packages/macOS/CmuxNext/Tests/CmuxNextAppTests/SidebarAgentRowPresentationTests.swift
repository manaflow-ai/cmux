import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextSidebar

/// Agent rows prefer a readable chat title and never manufacture a raw prompt subtitle.
struct SidebarAgentRowPresentationTests {
    @Test func aNamedChatTitleWinsOverItsSessionName() {
        let named: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "title": "Review the release", "titleSource": "generated"]
        #expect(AgentTurnStates.title(named) == "Review the release")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func aPromptWithoutAReadableTitleIsNotAStableTitle() {
        let promptOnly: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "lastPrompt": "Implement the adapter"]
        #expect(AgentTurnStates.title(promptOnly, includingPrompt: false) == nil)
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: nil, taskSummary: "Implement the adapter") == "Implement the adapter")
    }

    @Test func statusAndRepositoryFactsRemainSeparateFromTitle() {
        let row = SidebarWorkspace(id: WorkspaceID("row"), title: "Review the release", directory: "~/work/repo", branch: "main", status: "Waiting")
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.detail == nil || content.detail?.contains("Implement") == false)
    }
}
