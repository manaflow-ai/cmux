@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// Resume Agent Session rows draw the agent's brand mark (design/agent-icons, R79).
struct HistoryPaletteMarkTests {
    private func agent(_ provider: String) -> HistoryEntry {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let session = AgentSession(machine: "local", provider: provider, sessionID: "s1", cwd: "/repo",
                                   startedAt: time, lastActivityAt: time)
        return HistoryEntry(id: "agent:local/\(provider)/s1", kind: .agent, time: time, title: provider, payload: .agent(session))
    }

    @Test func agentRowsCarryTheirProvidersBrand() {
        #expect(HistoryPalettePages.agentBrand(agent("claude")) == "claude")
        #expect(HistoryPalettePages.agentBrand(agent("claude-code")) == "claude")
        #expect(HistoryPalettePages.agentBrand(agent("codex")) == "openai")
        #expect(HistoryPalettePages.agentBrand(agent("amp")) == "amp")
        #expect(HistoryPalettePages.agentBrand(agent("prime")) == nil)
        let page = HistoryEntry(id: "page:1", kind: .page, time: Date(), title: "x", payload: .page(url: "https://a.b", profile: "default"))
        #expect(HistoryPalettePages.agentBrand(page) == nil)
    }
}
