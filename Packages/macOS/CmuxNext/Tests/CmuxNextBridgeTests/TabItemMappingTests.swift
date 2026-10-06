@testable import CmuxNextDaemon
import Foundation
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge

/// A tab shows its terminal's progress as the daemon parses it for every
/// terminal, not only the mounted ones: running progress spins the icon,
/// an error marks the tab failed.
@MainActor
struct TabItemMappingTests {
    /// An agent terminal wears its agent's brand mark (design/agent-icons, R79); a terminal
    /// without an agent, or whose agent has no mark, keeps the terminal symbol.
    @Test func agentTerminalWearsItsBrandMark() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .symbol("terminal"))
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "claude"))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .agentMark("claude"))
        tab.setAgent(AgentStatus(surface: 1, state: .idle, agent: "codex"))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .agentMark("openai"))
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "hermes-agent"))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .agentMark("hermes"))
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "prime-agent"))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .symbol("terminal"))
    }

    @Test func terminalProgressFromTheDaemonDrivesTheTab() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        let terminal = try #require(tab.terminalResourceID)
        #expect(!TabItemMapping.shared.item(tab, fallbackTitle: "t").isBusy)

        var state = SessionStateMirror()
        state.terminalProgress[terminal] = TerminalProgressReport(state: .normal, value: 40)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .sessionState(.snapshot(state)))])
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").isBusy)

        state.terminalProgress[terminal] = TerminalProgressReport(state: .error, value: 40)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .sessionState(.snapshot(state)))])
        let failed = TabItemMapping.shared.item(tab, fallbackTitle: "t")
        #expect(!failed.isBusy && failed.status == .failure)

        state.terminalProgress[terminal] = nil
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .sessionState(.snapshot(state)))])
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .none)
    }
}

/// An agent chat tab (a conversation tab whose source is an acpmux session)
/// wears the agent chat symbol, not Home's conversation symbol.
@MainActor
struct AgentSessionTabItemTests {
    @Test func anAgentSessionTabWearsTheAgentChatSymbol() throws {
        let line = #"""
        {"surface":8,"kind":"conversation","browser_renderer":"frontend","title":"about:blank",
         "conversation":{"agent_session":{"host":"install:mac-1","session":"s-1","harness":null}}}
        """#
        let tab = TabModel(try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8)))
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Chat")
        #expect(item.icon == .symbol("bubble.left.and.text.bubble.right"))
        #expect(item.title == "Chat")
    }
}
