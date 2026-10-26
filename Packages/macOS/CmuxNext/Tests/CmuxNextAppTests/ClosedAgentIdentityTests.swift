import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// A closed New Tab chat keeps its agent identity in the native Recently Closed projection.
@MainActor
struct ClosedAgentIdentityTests {
    @Test func closedAgentSessionDecodesAndProjectsAsAgent() throws {
        let item = try Self.closed()
        let tab = try #require(item.tabs.first)
        #expect(tab.agentSession?.session == "sess-closed-chat")
        #expect(tab.agentSession?.harness == "codex")

        let history = CmuxNextHistory.ClosedItem(
            id: "daemon:closed_1", kind: .browserTab, title: "Fix the flaky upload test", machine: "local",
            agentSession: .init(sessionID: tab.agentSession?.session, harness: tab.agentSession?.harness))
        #expect(NewTabClosed.kind(for: history) == .agent)
        let row = AgentPaneClosedItem(id: "closed:daemon:closed_1", kind: .agent, title: history.title, detail: nil,
                                      closedAt: Date(timeIntervalSince1970: 1), icon: nil, isAvailable: true)
        #expect(row.json["kind"]?.stringValue == "agent")
    }

    @Test @MainActor func closedAgentTitleUsesLocalGeneratedTitleAndStableFallback() {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:closed-title"
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [],
                      titles: ["sess-closed-chat": "Prompt fallback"],
                      generatedTitles: ["sess-closed-chat": "Generated chat title"], details: [:])
        let session = CmuxNextHistory.ClosedItem.AgentSession(sessionID: "sess-closed-chat", harness: "codex")

        #expect(NewTabClosed.title("about:blank", nil, "/tmp/project", agentSession: session, machine: "local",
                                   localHost: "install:closed-title", turns: turns) == "Generated chat title")
        #expect(NewTabClosed.title("about:blank", nil, "/tmp/project", manualTitle: "Pinned chat", agentSession: session,
                                   machine: "local", localHost: "install:closed-title", turns: turns) == "Pinned chat")
        #expect(NewTabClosed.title("about:blank", nil, "/tmp/project", agentSession: session, machine: "remote",
                                   localHost: "install:closed-title", turns: turns) == AgentPaneModel.tabTitle)
    }

    @Test @MainActor func sameSessionIDKeepsEachWatchTitleSeparate() {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:closed-title"
        turns.mirroredHosts = ["chief:closed-title"]
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: [:],
                      generatedTitles: ["same-session": "Local title"], details: [:])
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: [:],
                      generatedTitles: ["same-session": "Chief title"], details: [:], source: "chief:closed-title")

        #expect(turns.generatedTitle(for: AgentSessionRef(host: "install:closed-title", session: "same-session")) == "Local title")
        #expect(turns.generatedTitle(for: AgentSessionRef(host: "chief:closed-title", session: "same-session")) == "Chief title")
    }

    private static func closed() throws -> CmuxNextDaemon.ClosedItem {
        let json = """
        {"id":"closed_1","kind":"tab","name":"Fix the flaky upload test","workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":1,
         "screens":[{"name":null,"tabs":[{"kind":"browser","name":"Fix the flaky upload test","cwd":null,"url":"about:blank","browser_profile_id":null,"pinned":false,
         "agent_session":{"session":"sess-closed-chat","harness":"codex"}}]}],"window":null,"member_count":1,"members":[]}
        """
        return try JSONDecoder().decode(CmuxNextDaemon.ClosedItem.self, from: Data(json.utf8))
    }
}
