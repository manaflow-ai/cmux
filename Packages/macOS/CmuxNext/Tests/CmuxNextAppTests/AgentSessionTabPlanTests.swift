import Testing
@testable import CmuxNextApp

/// Where a session's chat opens (`agent.openSessionTab`, a sidebar sub-session click, a chat's
/// `chat.offer.open`, auto-open) and what `agent.openSessionWorkspace` does: a tab that shows the
/// session already always wins, so one chat never streams in two tabs.
struct AgentSessionTabPlanTests {
    @Test func aTabThatShowsTheSessionIsReused() {
        #expect(AgentSessionTabPlan<String>.choose(existing: "tab-1", anchor: "parent", pane: "pane-1") == .existing(tab: "tab-1"))
        #expect(AgentSessionTabPlan<String>.choose(existing: "tab-1", anchor: nil, pane: nil) == .existing(tab: "tab-1"))
    }

    @Test func aNewTabOpensBesideItsParentBeforeAnyPane() {
        #expect(AgentSessionTabPlan<String>.choose(existing: nil, anchor: "parent", pane: "pane-1") == .beside(anchor: "parent"))
        #expect(AgentSessionTabPlan<String>.choose(existing: nil, anchor: "parent", pane: nil) == .beside(anchor: "parent"))
    }

    @Test func withoutAParentTabItOpensInThePane() {
        #expect(AgentSessionTabPlan<String>.choose(existing: nil, anchor: nil, pane: "pane-1") == .pane("pane-1"))
    }

    @Test func withNowhereToOpenItIsRefused() {
        #expect(AgentSessionTabPlan<String>.choose(existing: nil, anchor: nil, pane: nil) == .refused)
    }

    /// `agent open SESSION` twice used to make two workspaces that both streamed the chat.
    @Test func openSessionWorkspaceRevealsTheTabThatShowsTheSession() {
        #expect(AgentSessionWorkspacePlan.choose(existing: "tab-1") == .reveal(tab: "tab-1"))
        #expect(AgentSessionWorkspacePlan.choose(existing: nil) == .create)
    }
}
