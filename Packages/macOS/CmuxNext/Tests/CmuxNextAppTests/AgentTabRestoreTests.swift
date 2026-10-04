import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// R138: after Cmd-Q with Keep, the acpmux session (and a running turn) survives, so its agent tab
/// comes back too. The tabs each pane lists are recorded in the daemon's window document and
/// reopened on their acpmux sessions at relaunch.
@MainActor
@Suite struct AgentTabRestoreTests {
    private static let mock = ["CMUX_NEXT_AGENT_PANE_MOCK": "1"]

    private func store() -> AgentTabStore {
        AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock)
    }

    @Test func everyChangeToAPanesAgentTabsIsReported() async throws {
        let tabs = store()
        var reported: [String: [AgentTabRecord]] = [:]
        tabs.onRecordsChanged = { pane, records in reported[pane] = records }
        let daemon = DaemonStore()
        let first = tabs.open(in: "pane-a", of: daemon, session: "s-1")
        let second = tabs.open(in: "pane-a", of: daemon)
        #expect(reported["pane-a"] == [AgentTabRecord(id: first, session: "s-1"), AgentTabRecord(id: second, session: nil)])
        // A new chat that gets its session is recorded with it.
        let view = try #require(tabs.view(for: second))
        _ = await view.model.respond(to: .persistSession("s-2"))
        #expect(reported["pane-a"]?.last == AgentTabRecord(id: second, session: "s-2"))
        tabs.close(first)
        #expect(reported["pane-a"] == [AgentTabRecord(id: second, session: "s-2")])
        tabs.closePane("pane-a")
        #expect(reported["pane-a"] == [])
    }

    @Test func restoredTabsComeBackWithTheirIdsAndSessions() {
        let tabs = store()
        let daemon = DaemonStore()
        let records = [AgentTabRecord(id: "local-agent:one", session: "s-1"), AgentTabRecord(id: "local-agent:two", session: "s-2")]
        tabs.restore(records, in: "pane-a", of: daemon)
        #expect(tabs.tabIDs(in: "pane-a") == ["local-agent:one", "local-agent:two"])
        #expect(tabs.session(of: "local-agent:two") == "s-2")
        // Restoring again (a second window document read) adds nothing.
        tabs.restore(records, in: "pane-a", of: daemon)
        #expect(tabs.tabIDs(in: "pane-a").count == 2)
        tabs.closePane("pane-a")
    }

    /// A tab that never got a session (an empty new chat) is not worth restoring.
    @Test func aTabWithoutASessionIsNotRestored() {
        let tabs = store()
        tabs.restore([AgentTabRecord(id: "local-agent:empty", session: nil)], in: "pane-a", of: DaemonStore())
        #expect(tabs.tabIDs(in: "pane-a").isEmpty)
    }

    @Test func theWindowDocumentKeepsAgentTabsPerPane() throws {
        var document = WindowStateDocument()
        document.agentTabs["pane-a"] = [AgentTabRecord(id: "local-agent:one", session: "s-1")]
        let data = try JSONEncoder().encode(document)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"agent_tabs\""))
        let decoded = try JSONDecoder().decode(WindowStateDocument.self, from: data)
        #expect(decoded.agentTabs == document.agentTabs)
        // An older document without the field still decodes.
        let old = try JSONDecoder().decode(WindowStateDocument.self, from: Data(#"{"windows":[]}"#.utf8))
        #expect(old.agentTabs.isEmpty)
    }
}
