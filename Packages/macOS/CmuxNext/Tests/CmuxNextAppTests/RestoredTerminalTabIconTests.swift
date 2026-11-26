import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// cmux#49392: a terminal tab running Claude Code drew a bare `>_` once the terminal was restored
/// or reopened. Its tab then has a surface of its own, while the daemon's agent report named the
/// terminal's runtime surface, so `tabsBySurface[status.surface]` found no tab and the tab never
/// learned its agent. The store now matches a status to its tab by the terminal's public id.
@MainActor @Suite struct RestoredTerminalTabIconTests {
    private static let terminal: ResourceID = "term_restored"

    /// One terminal tab on `surface`, showing terminal `term_restored`.
    private func tree(surface: SurfaceID) -> DaemonTree {
        let tab = TabSnapshot(surface: surface, tabResourceID: "tab_restored", terminalResourceID: Self.terminal, title: "Claude Code")
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    /// The agent as the daemon reports it: on `surface`, which need not be the tab's.
    private func claude(on surface: SurfaceID, terminal: ResourceID? = terminal, at ms: UInt64 = 100) -> AgentStatus {
        AgentStatus(surface: surface, terminalID: terminal, state: .idle, source: "hook", agent: "claude", updatedAtMs: ms)
    }

    private func icon(_ store: DaemonStore) throws -> TabIcon {
        let tab = try #require(store.workspaces.first?.allTabs.first)
        return TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").icon
    }

    @Test func anAgentReportOnTheRuntimeSurfaceMarksTheRestoredTab() throws {
        let store = DaemonStore()
        store.apply(snapshot: tree(surface: 12))
        #expect(try icon(store) == .terminal)
        _ = store.apply(.agentChanged(claude(on: 3)))
        #expect(try icon(store) == .terminalAgentMark("claude"), "the tab of the reported terminal draws Claude's mark")
    }

    @Test func theConnectSeedMarksTheRestoredTab() throws {
        let store = DaemonStore()
        store.apply(snapshot: tree(surface: 12))
        store.apply(agents: [claude(on: 3)])
        #expect(try icon(store) == .terminalAgentMark("claude"))
    }

    /// The terminal restored into a tab with a new surface after the agent last reported: the tab
    /// keeps its agent with no new report.
    @Test func aTabThatARestoreGaveANewSurfaceKeepsItsAgent() throws {
        let store = DaemonStore()
        store.apply(snapshot: tree(surface: 3))
        _ = store.apply(.agentChanged(claude(on: 3)))
        #expect(try icon(store) == .terminalAgentMark("claude"))
        store.apply(snapshot: tree(surface: 12))
        #expect(try icon(store) == .terminalAgentMark("claude"))
    }

    /// An older daemon names no terminal: the surface alone still matches, and a status for
    /// another surface still marks nothing.
    @Test func aStatusWithoutATerminalMatchesBySurfaceOnly() throws {
        let store = DaemonStore()
        store.apply(snapshot: tree(surface: 12))
        _ = store.apply(.agentChanged(claude(on: 3, terminal: nil)))
        #expect(try icon(store) == .terminal)
        _ = store.apply(.agentChanged(claude(on: 12, terminal: nil, at: 200)))
        #expect(try icon(store) == .terminalAgentMark("claude"))
    }

    /// A terminal shown in two tabs (two views, two surfaces): a report on a third surface marks both.
    @Test func everyTabOfTheTerminalLearnsItsAgent() throws {
        let store = DaemonStore()
        let tabs = [12, 13].map { TabSnapshot(surface: SurfaceID(rawValue: $0), tabResourceID: ResourceID(rawValue: "tab_\($0)"),
                                              terminalResourceID: Self.terminal, title: "Claude Code") }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        _ = store.apply(.agentChanged(claude(on: 3)))
        let views = try #require(store.workspaces.first?.allTabs)
        #expect(views.count == 2)
        #expect(views.map { TabItemMapping.shared.item($0, fallbackTitle: "Terminal").icon } == [.terminalAgentMark("claude"), .terminalAgentMark("claude")])
    }

    @Test func agentChangedDecodesTheTerminal() throws {
        let json = #"{"surface":3,"terminal_id":"term_restored","state":"working","source":"hook","session":null,"agent":"claude","updated_at_ms":1}"#
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(json.utf8))
        #expect(status.terminalID == Self.terminal)
        #expect(status.surface == 3)
    }
}
