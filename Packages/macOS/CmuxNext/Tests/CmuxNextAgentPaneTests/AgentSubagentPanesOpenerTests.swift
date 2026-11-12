import Testing
@testable import CmuxNextAgentPane

/// A subagent pane's "Subagent of" pill goes back to the chat tab that opened it (`chat.subagentBack`,
/// Lucas 2026-11-06: "close the subagent tab, and bring them back to the open chat instead"). The app
/// finds that tab through the tracker that remembers the subagent's tab.
@Suite
@MainActor
struct AgentSubagentPanesOpenerTests {
    @Test func aRememberedSubagentTabNamesTheChatTabThatOpenedIt() {
        let session = "opener-\(UInt64.random(in: 0...UInt64.max))"
        AgentSubagentPanes.chat(session, source: "chat-tab").record("agent-1", tab: "provisional-1")
        AgentSubagentPanes.chat(session, source: "other-chat").record("agent-2", tab: "sub-2")
        let resolved = ["provisional-1": "sub-1"]
        let resolve: (String) -> String = { resolved[$0] ?? $0 }

        #expect(AgentSubagentPanes.opener(ofTab: "sub-1", resolve: resolve) == "chat-tab")
        #expect(AgentSubagentPanes.opener(ofTab: "sub-2", resolve: resolve) == "other-chat")
    }

    @Test func aTabNoTrackerRemembersHasNoOpener() {
        // A subagent pane opened from somewhere else (a link, the sidebar): the page shows the chat in place.
        #expect(AgentSubagentPanes.opener(ofTab: "never-opened-\(UInt64.random(in: 0...UInt64.max))", resolve: { $0 }) == nil)
    }
}

@Suite
@MainActor
struct AgentSubagentPanesBackTests {
    @Test func backFocusesTheOpeningChatThenClosesTheSubagentTab() {
        let session = "back-\(UInt64.random(in: 0...UInt64.max))"
        AgentSubagentPanes.chat(session, source: "chat-tab").record("agent-1", tab: "sub-1")
        var calls: [String] = []
        let back = AgentSubagentPanes.back(from: "sub-1", resolve: { $0 }, exists: { _ in true },
                                           focus: { calls.append("focus \($0)") }, close: { calls.append("close \($0)") })
        #expect(back)
        #expect(calls == ["focus chat-tab", "close sub-1"])
    }

    @Test func noBackWhenTheOpeningChatIsGone() {
        let session = "gone-\(UInt64.random(in: 0...UInt64.max))"
        AgentSubagentPanes.chat(session, source: "closed-chat").record("agent-1", tab: "sub-2")
        var calls: [String] = []
        let back = AgentSubagentPanes.back(from: "sub-2", resolve: { $0 }, exists: { _ in false },
                                           focus: { calls.append($0) }, close: { calls.append($0) })
        #expect(!back)
        #expect(calls.isEmpty)
    }
}
