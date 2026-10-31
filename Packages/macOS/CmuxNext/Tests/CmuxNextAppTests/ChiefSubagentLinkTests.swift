import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import Testing
import Observation
import CmuxNextCompat

/// Lawrence 2026-10-30: clicking "a919" in Home's chat said "the linked item is gone" while a919
/// ran. Its spawn made no workspace (this Mac was out of PTYs), and a subagent link only revealed
/// a tab that already showed the session. A live subagent's link opens its chat as its sidebar
/// row does: the tab that shows it, else a new workspace on its session (a chat tab, no PTY).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ChiefSubagentLinkTests {
    /// A fake App: `shown` maps a session to the tab showing it; records reveals and opens.
    @Observable final class FakeApp {
        var shown: [String: String] = [:]
        var revealed: [String] = []
        var opened: [(session: String, host: String)] = []

        func host(chief: String = "chief:6b68ac4a") -> ChiefSidebar.Host {
            .init(conversation: { nil }, chiefHost: { chief },
                  tab: { [unowned self] session, _ in shown[session] },
                  openedSessions: { [unowned self] _ in Set(shown.keys) },
                  reveal: { [unowned self] tab in revealed.append(tab); return true },
                  openWorkspace: { [unowned self] session, host in
                      opened.append((session, host))
                      shown[session] = "tab-" + session
                      return Task { nil }
                  })
        }
    }

    @Test func aLinkToASubagentNoTabShowsOpensAWorkspaceOnItsChat() async {
        let app = FakeApp()
        let sidebar = ChiefSidebar(lanes: AgentLaneStore(), host: app.host())
        let opened = sidebar.openSubagentLink(session: "optchat-sub-6b68ac4a-a919", chiefHost: "chief:6b68ac4a",
                                              registry: ActionRegistry())
        #expect(opened, "a live subagent's link read as gone")
        #expect(app.opened.map(\.session) == ["optchat-sub-6b68ac4a-a919"])
        #expect(app.opened.map(\.host) == ["chief:6b68ac4a"])
        // The new workspace's chat tab comes forward once its work ends.
        for _ in 0..<50 where app.revealed.isEmpty { await Task.yield() }
        #expect(app.revealed == ["tab-optchat-sub-6b68ac4a-a919"])
    }

    @Test func aLinkToAShownSubagentRevealsItsTabAndOpensNothing() {
        let app = FakeApp()
        app.shown["s-1"] = "tab-1"
        let sidebar = ChiefSidebar(lanes: AgentLaneStore(), host: app.host())
        #expect(sidebar.openSubagentLink(session: "s-1", chiefHost: "chief:6b68ac4a", registry: ActionRegistry()))
        #expect(app.revealed == ["tab-1"])
        #expect(app.opened.isEmpty)
    }

    @Test func sidebarRowsFollowOpenedTabsWithoutASessionWorkspaceBinding() async {
        let app = FakeApp()
        let lanes = AgentLaneStore()
        let lane = AgentActivityLane(id: "s-1", name: "optchat-sub-6b68ac4a-a1", title: "Inspect change",
                                     peer: nil, parent: "optchat-chief:6b68ac4a", state: .working,
                                     since: nil, error: nil)
        lanes.lanes = [lane.id: lane]
        let sidebar = ChiefSidebar(lanes: lanes, host: app.host())
        #expect(lane.workspaceID == nil, "a session opened after spawning has no creation-time workspace binding")
        #expect(sidebar.rows().isEmpty)
        #expect(sidebar.allSubagents().count == 1)
        var rows = ObservationStream { sidebar.rows().map(\.info.title) }.makeAsyncIterator()
        #expect(await rows.next() == [])
        #expect(sidebar.openSubagentLink(session: lane.id, chiefHost: "chief:6b68ac4a", registry: ActionRegistry()))
        #expect(await rows.next() == ["Inspect change"], "opening a tab updates the sidebar without another lane event")
        app.shown.removeValue(forKey: lane.id)
        #expect(await rows.next() == [], "closing the tab removes its transient row without ending the session")
        #expect(sidebar.allSubagents().count == 1)
    }

    @Test func anotherChiefsSubagentLinkOpensNothing() {
        let app = FakeApp()
        let sidebar = ChiefSidebar(lanes: AgentLaneStore(), host: app.host())
        #expect(!sidebar.openSubagentLink(session: "s-1", chiefHost: "chief:00000000", registry: ActionRegistry()))
        #expect(app.opened.isEmpty && app.revealed.isEmpty)
    }
}
