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
    func daemonHistoryEnrichmentUsesMachineAndClosedID(_ id: String) throws {
        let row = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"\(id)","kind":"closed","at_ms":"1","title":"",
             "closed_kind":"browser_tab","available":true}
            """.utf8))
        let original = try #require(row.historyEntry(untitled: "Terminal fallback"))
        let record = CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .browserTab,
                                               title: AgentPaneModel.tabTitle, machine: "local",
                                               agentSession: .init(sessionID: "same-session", harness: "codex"))
        let known = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: original.time,
                                 title: record.title, payload: .closed(record))
        let enriched = try #require(HistoryService.enrichClosedEntries([original], from: [known]).first)
        #expect(enriched.id == original.id)
        #expect(enriched.title == AgentPaneModel.tabTitle)
        #expect(HistoryPalettePages.agentBrand(enriched) != nil)
        guard case .closed(let item) = enriched.payload else { Issue.record("not a closed row"); return }
        #expect(item.id == String(id.dropFirst("closed:".count)))
        #expect(item.agentSession?.sessionID == "same-session")
        #expect(NewTabClosed.kind(for: item) == .agent)

        var otherMachine = known
        var otherRecord = record
        otherRecord.machine = "remote"
        otherMachine.payload = .closed(otherRecord)
        #expect(HistoryService.enrichClosedEntries([original], from: [otherMachine]) == [original])
        otherRecord.machine = "local"
        otherRecord.id = "daemon:closed_2"
        otherMachine.payload = .closed(otherRecord)
        #expect(HistoryService.enrichClosedEntries([original], from: [otherMachine]) == [original])
    }

    @Test func daemonClosedSearchFiltersAfterEnrichmentAndBeforeLimit() async throws {
        // Put the matching chat beyond both the requested limit and the daemon's default
        // 500-row page. Newer unrelated rows must not crowd it out before enrichment.
        let rows = try (1...501).map { index in
            try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
                {"id":"closed:closed_\(index)","kind":"closed","at_ms":"\(index)",
                 "title":"\(index == 1 ? "" : "Other")","closed_kind":"browser_tab","available":true}
                """.utf8))
        }
        let original = try #require(rows.first?.historyEntry(untitled: "Terminal fallback"))
        let record = CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .browserTab,
                                               title: AgentPaneModel.tabTitle, machine: "local",
                                               agentSession: .init(sessionID: "same-session", harness: "codex"))
        let known = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: original.time,
                                 title: record.title, payload: .closed(record))
        for text in ["same-session", "codex", AgentPaneModel.tabTitle, "no-such-chat"] {
            let query = HistoryQuery(text: text, kinds: [.closed], limit: 1)
            let matches = await HistoryService.filteredClosedDaemonEntries(query, closed: { [known] }) { request in
                #expect(request.kinds == [.closed])
                #expect(request.range == query.range)
                var daemonQuery = request
                daemonQuery.limit = request.limit ?? 500
                let raw = rows.compactMap { $0.historyEntry(untitled: "Terminal fallback") }
                let ids = Set(daemonQuery.apply(to: raw).map(\.id))
                return rows.filter { ids.contains($0.id) }
            }
            #expect(matches.map(\.id) == (text == "no-such-chat" ? [] : [original.id]))
            if let match = matches.first {
                #expect(match.title == AgentPaneModel.tabTitle)
                guard case .closed(let item) = match.payload else { Issue.record("not closed"); return }
                #expect(item.agentSession?.sessionID == "same-session")
            }
        }
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
