import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// acpmux turn state (`_acpmux/watch` + `session_changed`) reduced per session.
struct AgentTurnStatesTests {
    static func summary(_ id: String, status: String, pending: Int = 0, lastTurn: String? = nil) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": id, "status": status, "pendingPermissions": pending]
        if let lastTurn { summary["lastTurn"] = ["turnId": "t-1", "status": lastTurn] }
        return summary
    }

    @Test func summariesMapToTurnStates() {
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "running")) == .working)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "waiting")) == .needsInput)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "running", pending: 1)) == .needsInput)
        for status in ["idle", "ready", "closed"] {
            #expect(AgentTurnState.of(summary: Self.summary("s", status: status)) == nil)
        }
    }

    /// The next prompt respawns a disconnected agent, so a disconnect alone
    /// is normal and looks idle. Only a turn that really failed is an error.
    @Test func aDisconnectLooksIdleUnlessTheLastTurnFailed() {
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "disconnected")) == nil)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "unreachable")) == nil)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "disconnected", lastTurn: "completed")) == nil)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "disconnected", lastTurn: "cancelled")) == nil)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "disconnected", lastTurn: "failed")) == .failed)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "ready", lastTurn: "failed")) == .failed)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "idle", lastTurn: "failed")) == .failed)
        // A new turn replaces the old outcome; a closed chat shows nothing.
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "running", lastTurn: "failed")) == .working)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "waiting", lastTurn: "failed")) == .needsInput)
        #expect(AgentTurnState.of(summary: Self.summary("s", status: "closed", lastTurn: "failed")) == nil)
    }

    @Test func watchResultThenPushesKeepTheStatesCurrent() {
        var states = AgentTurnStates()
        states.reset(["sessions": [Self.summary("a", status: "running"), Self.summary("b", status: "ready")]])
        #expect(states["a"] == .working)
        #expect(states["b"] == nil)
        states.apply(changed: ["sessionId": "b", "kind": "status", "session": Self.summary("b", status: "waiting")])
        #expect(states["b"] == .needsInput)
        states.apply(changed: ["sessionId": "a", "kind": "status", "session": Self.summary("a", status: "ready")])
        #expect(states["a"] == nil)
        states.apply(changed: ["sessionId": "b", "kind": "purged"])
        #expect(states["b"] == nil)
        states.apply(changed: ["sessionId": "c", "kind": "status", "session": Self.summary("c", status: "running")])
        states.clear()
        #expect(states["c"] == nil)
    }
}

/// An agent chat tab and its workspace row show the acpmux turn: working
/// dots while a turn runs, a still attention dot while it needs input.
@MainActor
struct AgentTurnIndicatorTests {
    static func chat(host: String = "install:mac-1", session: String = "s-1") throws -> TabModel {
        let line = """
        {"surface":8,"kind":"conversation","browser_renderer":"frontend","title":"about:blank",
         "conversation":{"agent_session":{"host":"\(host)","session":"\(session)","harness":"claude"}}}
        """
        return TabModel(try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8)))
    }

    static func store(_ status: String, pending: Int = 0) -> AgentTurnStateStore {
        let store = AgentTurnStateStore()
        store.localHost = "install:mac-1"
        store.states.reset(["sessions": [AgentTurnStatesTests.summary("s-1", status: status, pending: pending)]])
        return store
    }

    @Test func aRunningTurnShowsWorkingOnTheTab() throws {
        let mapping = StatusMapping(turns: Self.store("running"))
        let tab = try Self.chat()
        let summary = mapping.loading(tab)
        #expect(summary.state == .working)
        #expect(summary.primary?.source == .agent)
        #expect(summary.primary?.label == "claude")
    }

    @Test func aTurnThatNeedsInputIsWaitingNotWorking() throws {
        let tab = try Self.chat()
        let mapping = StatusMapping(turns: Self.store("running", pending: 1))
        #expect(mapping.summary(tab).state == .waiting)
        // The icon slot shows loading and work only; the badge marks waiting.
        #expect(mapping.loading(tab) == .idle)
        #expect(mapping.turn(tab) == .needsInput)
    }

    @Test func anotherMachinesChatHasNoLocalState() throws {
        let mapping = StatusMapping(turns: Self.store("running"))
        #expect(mapping.summary(try Self.chat(host: "install:other")) == .idle)
        #expect(mapping.summary(try Self.chat(session: "s-2")) == .idle)
    }

    @Test func aWorkingTerminalAgentIsWorkingNotLoading() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "claude"))
        #expect(StatusMapping.shared.summary(tab).state == .working)
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.indicator == .working)
        #expect(item.isBusy)
    }

    /// `appearance.statusIndicator.showAgentWorkingOnTabs` off: the tab keeps
    /// its icon; the row is the row-content setting's business.
    @Test func turningTabWorkingOffKeepsTheIcon() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "claude"))
        let saved = DesignSettings.shared.statusIndicator
        defer { DesignSettings.shared.statusIndicator = saved }
        DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs = false
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.indicator == .idle)
        #expect(!item.isBusy)
        #expect(StatusMapping.shared.summary(tab).state == .working)
    }

    /// OSC 7501 from any terminal program: working draws the working mark
    /// (a determinate accent ring with progress), blocked is needs input.
    @Test func programStatusDrivesTheSameIndicators() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let tab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first)
        tab.programStatus = [ProgramStatusRecord(state: .working, progress: 40, app: "cargo", title: "Build", updatedSeq: 1)]
        let working = StatusMapping.shared.loading(tab)
        #expect(working.state == .working(progress: 0.4))
        #expect(working.primary?.source == .program)
        #expect(working.primary?.label == "Build")
        #expect(SidebarMapping.shared.row(workspace, machine: .local).activity == .working(progress: 0.4))
        tab.programStatus.append(ProgramStatusRecord(id: "deploy", state: .blocked, kind: .permission, updatedSeq: 2))
        #expect(StatusMapping.shared.summary(tab).state == .waiting)
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .needsInput)
        #expect(SidebarMapping.shared.row(workspace, machine: .local).activity == .waiting)
        tab.programStatus = [ProgramStatusRecord(state: .idle, updatedSeq: 3)]
        #expect(StatusMapping.shared.summary(tab) == .idle)
    }

    @Test func theRowShowsWorkingWhenAnyTabWorks() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let tab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first)
        tab.setAgent(AgentStatus(surface: 1, state: .working))
        let row = SidebarMapping.shared.row(workspace, machine: .local)
        #expect(row.activity == .working)
    }
}

/// The row's working slot (`WorkspaceRowContent.showsWorking`, nx/row-content)
/// follows every agent-work source: an acpmux turn, a hook and OSC 7501, and
/// any working tab even while another tab of the workspace waits.
@MainActor
struct RowWorkingSlotTests {
    @Test func anAcpTurnOrAProgramReportFillsTheRowsWorkingSlot() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let tab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first)
        tab.programStatus = [ProgramStatusRecord(state: .working, updatedSeq: 1)]
        let row = SidebarMapping.shared.row(workspace, machine: .local)
        #expect(row.agentWorking)
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.showsWorking)
        #expect(content.activity == .working)
    }

    @Test func aWaitingTabDoesNotHideAnotherTabsWork() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.screens.flatMap(\.panes).flatMap(\.tabs).count >= 2 })
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        tabs[0].programStatus = [ProgramStatusRecord(state: .working, updatedSeq: 1)]
        tabs[1].programStatus = [ProgramStatusRecord(state: .blocked, kind: .question, updatedSeq: 2)]
        let row = SidebarMapping.shared.row(workspace, machine: .local)
        #expect(row.activity == .waiting)
        #expect(row.agentWorking)
    }
}
