import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// A closed New Tab chat keeps its agent identity in the native Recently Closed projection.
@MainActor
struct ClosedAgentIdentityTests {
    @Test(arguments: ["browser", "conversation"])
    func closedAgentSessionDecodesAndProjectsAsAgent(_ kind: String) throws {
        let item = try Self.closed(kind: kind)
        let tab = try #require(item.tabs.first)
        #expect(tab.agentSession?.session == "sess-closed-chat")
        #expect(tab.agentSession?.harness == "codex")

        let history = CmuxNextHistory.ClosedItem(
            id: "daemon:closed_1", kind: HistoryService.closedKind(item), title: "Fix the flaky upload test", machine: "local",
            agentSession: .init(sessionID: tab.agentSession?.session, harness: tab.agentSession?.harness))
        #expect(history.kind == (kind == "conversation" ? .conversationTab : .browserTab))
        #expect(NewTabClosed.kind(for: history) == .agent)
        let row = AgentPaneClosedItem(id: "closed:daemon:closed_1", kind: .agent, title: history.title, detail: nil,
                                      closedAt: Date(timeIntervalSince1970: 1), icon: nil, isAvailable: true)
        #expect(row.json["kind"]?.stringValue == "agent")
    }

    @Test(arguments: ["closed:daemon:closed_1", "closed:closed_1"])
    func daemonClosedChatKeepsItsIDAndTakesTheChatTitle(_ id: String) throws {
        let row = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"\(id)","kind":"closed","at_ms":"1","title":"",
             "closed_kind":"browser_tab","available":true,"session_id":"same-session","provider":"codex"}
            """.utf8))
        let entry = try #require(row.historyEntry(untitled: "Terminal fallback", untitledChat: AgentPaneModel.tabTitle))
        #expect(entry.id == id)
        #expect(entry.title == AgentPaneModel.tabTitle)
        guard case .closed(let item) = entry.payload else { Issue.record("not a closed row"); return }
        #expect(item.id == String(id.dropFirst("closed:".count)))
        #expect(item.title == AgentPaneModel.tabTitle)
        #expect(NewTabClosed.kind(for: item) == .agent)
    }

    /// The daemon's closed row names a chat's session and harness (cmux-tui `closed_entry`, #31871), so the
    /// app reads the agent identity from the row itself, with no second read of the closed records.
    @Test func daemonClosedRowCarriesItsAgentIdentity() throws {
        let row = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"closed:daemon:closed_1","kind":"closed","at_ms":"1","title":"",
             "closed_kind":"browser_tab","available":true,"session_id":"same-session","provider":"codex"}
            """.utf8))
        let entry = try #require(row.historyEntry(untitled: "Terminal fallback"))
        guard case .closed(let item) = entry.payload else { Issue.record("not a closed row"); return }
        #expect(item.id == "daemon:closed_1")
        #expect(item.agentSession?.sessionID == "same-session")
        #expect(item.agentSession?.harness == "codex")
        #expect(NewTabClosed.kind(for: item) == .agent)
        #expect(entry.agentBrand != nil)
        #expect(entry.searchText.contains("same-session"))

        let plain = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"closed:daemon:closed_2","kind":"closed","at_ms":"1","title":"",
             "closed_kind":"browser_tab","available":true}
            """.utf8))
        let plainEntry = try #require(plain.historyEntry(untitled: "Terminal fallback"))
        guard case .closed(let plainItem) = plainEntry.payload else { Issue.record("not a closed row"); return }
        #expect(plainItem.agentSession == nil)
        #expect(plainEntry.title == "Terminal fallback")
    }

    @Test func closedContainersRetainTheirOwnKind() throws {
        var item = try Self.closed()
        #expect(HistoryService.closedAgentSession(item)?.harness == "codex")
        for kind in [CmuxNextDaemon.ClosedItem.Kind.screen, .workspace, .window] {
            item.kind = kind
            #expect(HistoryService.closedAgentSession(item) == nil)
        }
    }

    @Test func nativeHandshakeAndHistoryDecodeCanonicalClosedKinds() throws {
        let echoed = DaemonCapability.handshakeCapabilities(DaemonCapability.advertised, resolvesShellIntegration: false)
        #expect(echoed.contains("closed-conversation-tabs-v1"))
        let row = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"closed:daemon:closed_1","kind":"closed","at_ms":"1","title":"Chat",
             "closed_kind":"conversation_tab","available":true}
            """.utf8))
        let entry = try #require(row.historyEntry(untitled: "Terminal"))
        guard case .closed(let item) = entry.payload else { Issue.record("not closed"); return }
        #expect(item.kind == .conversationTab)
        #expect(NewTabClosed.kind(for: item) == .agent)
    }

    @Test func plainBrowserRetainsBrowserKind() throws {
        var item = try Self.closed()
        item.screens[0].tabs[0].agentSession = nil
        let history = CmuxNextHistory.ClosedItem(id: item.id, kind: HistoryService.closedKind(item), title: "Browser", machine: "local")
        #expect(history.kind == .browserTab)
        #expect(NewTabClosed.kind(for: history) == .browser)
    }

    private static func closed(kind: String = "browser") throws -> CmuxNextDaemon.ClosedItem {
        let json = """
        {"id":"closed_1","kind":"tab","name":"Fix the flaky upload test","workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":1,
         "screens":[{"name":null,"tabs":[{"kind":"\(kind)","name":"Fix the flaky upload test","cwd":null,"url":"about:blank","browser_profile_id":null,"pinned":false,
         "agent_session":{"session":"sess-closed-chat","harness":"codex"}}]}],"window":null,"member_count":1,"members":[]}
        """
        return try JSONDecoder().decode(CmuxNextDaemon.ClosedItem.self, from: Data(json.utf8))
    }
}
