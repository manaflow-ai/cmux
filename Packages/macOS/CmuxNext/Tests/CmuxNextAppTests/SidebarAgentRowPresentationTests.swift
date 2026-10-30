import Foundation
@testable import CmuxNextDaemon
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextSidebar

/// Agent rows prefer a readable chat title and never manufacture a raw prompt subtitle.
struct SidebarAgentRowPresentationTests {
    @Test func aNamedChatTitleWinsOverItsSessionName() {
        let named: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "title": "Review the release", "titleSource": "generated"]
        #expect(AgentTurnStates.title(named, includingPrompt: false) == "Review the release")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func aPromptWithoutAReadableTitleIsNotAStableTitle() {
        let promptOnly: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "lastPrompt": "Implement the adapter"]
        #expect(AgentTurnStates.title(promptOnly, includingPrompt: false) == nil)
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: nil, taskSummary: "Implement the adapter") == "Implement the adapter")
    }

    @Test func aRenamedAgentWorkspaceKeepsTheUserName() {
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "My review", sessionName: "lane-1",
                                             chatTitle: "Review the release", taskSummary: "Implement the adapter") == "My review")
    }

    @MainActor
    @Test func anUnbrandedHarnessStillGetsAReadableTaskTitle() throws {
        var chat = TabSnapshot(surface: 1, kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(
            host: "install:sidebar-title-fixture", session: "demo-lane", harness: "custom-fixture-harness"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "demo-lane", screens: [screen])
        ]))
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        tab.agent = AgentStatus(surface: 1, state: .working, agent: "custom-fixture-harness",
                                lastPrompt: "Your task:\nTitle: Review the release\nCheck the build and report failures.")
        #expect(tab.agentBrand == nil)
        #expect(SidebarMapping.shared.row(workspace, machine: .local).title == "Review the release")
    }

    @Test func statusAndRepositoryFactsRemainSeparateFromTitle() {
        let row = SidebarWorkspace(id: WorkspaceID("row"), title: "Review the release", directory: "~/work/repo", branch: "main", status: "Waiting")
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.detail == nil || content.detail?.contains("Implement") == false)
    }
}
