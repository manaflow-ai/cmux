import CmuxNextAgentActivity
@testable import CmuxNextApp
import Foundation
import Testing

/// Picking a chat in the sidebar's Priority view goes to where that chat lives. Before, every pick
/// went to the active window's focused pane, so a session bound to another workspace replaced what
/// the person was looking at instead of switching to its own workspace (Leo 2026-10-21: it
/// "doesn't jump to another workspace, it overrides this workspace").
@Suite struct AgentChatJumpTests {
    private static func lane(_ id: String, workspace: String?) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: .input,
                          since: nil, error: nil, workspaceID: workspace)
    }

    @Test func aChatBoundToAnotherWorkspaceOpensInThatWorkspace() {
        let jump = AgentChatJump.decide(lane: Self.lane("s1", workspace: "ws-1"), shownIn: nil,
                                        hasWorkspace: { $0 == "ws-1" })
        #expect(jump == .openInWorkspace(workspaceID: "ws-1", session: "s1"))
    }

    @Test func aTabAlreadyShowingTheChatIsRevealedWhereverItLives() {
        let jump = AgentChatJump.decide(lane: Self.lane("s1", workspace: "ws-1"), shownIn: "tab-9",
                                        hasWorkspace: { _ in true })
        #expect(jump == .revealTab("tab-9"))
    }

    @Test func withNoWorkspaceOfItsOwnTheChatOpensInTheFocusedPane() {
        #expect(AgentChatJump.decide(lane: Self.lane("s1", workspace: nil), shownIn: nil,
                                     hasWorkspace: { _ in true }) == .openInFocusedPane(session: "s1"))
        #expect(AgentChatJump.decide(lane: Self.lane("s1", workspace: "gone"), shownIn: nil,
                                     hasWorkspace: { _ in false }) == .openInFocusedPane(session: "s1"))
    }

    /// The window can show the workspace before its panes mount. The jump used to give up there
    /// ("no pane") and the chat never opened.
    @Test func aWorkspaceWithNoPaneYetWaitsForOne() {
        #expect(AgentChatJump.PaneWait.decide(showing: "ws-1", workspaceID: "ws-1", hasPane: false) == .wait)
        #expect(AgentChatJump.PaneWait.decide(showing: "ws-1", workspaceID: "ws-1", hasPane: true) == .open)
    }

    @Test func theWaitEndsWhenTheWindowLeavesTheWorkspace() {
        #expect(AgentChatJump.PaneWait.decide(showing: "ws-2", workspaceID: "ws-1", hasPane: true) == .stop)
        #expect(AgentChatJump.PaneWait.decide(showing: nil, workspaceID: "ws-1", hasPane: false) == .stop)
    }
}
