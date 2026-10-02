import CmuxNextDesign
import CmuxNextSidebar
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// Daemon status facts become the indicator state of tabs and rows.
@MainActor
struct StatusMappingTests {
    func tabs(_ store: DaemonStore, workspace name: String) throws -> [TabModel] {
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == name })
        return workspace.screens.flatMap(\.panes).flatMap(\.tabs)
    }

    @Test func agentHookStatesMapToIndicatorStates() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(try tabs(store, workspace: "beta").first)
        #expect(StatusMapping.shared.summary(tab) == .idle)
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "claude", updatedAtMs: 5))
        let working = StatusMapping.shared.summary(tab)
        #expect(working.state == .busy)
        #expect(working.primary?.label == "claude")
        #expect(working.primary?.source == .agent)
        tab.setAgent(AgentStatus(surface: 1, state: .blocked))
        #expect(StatusMapping.shared.summary(tab).state == .waiting)
        tab.setAgent(AgentStatus(surface: 1, state: .done))
        #expect(StatusMapping.shared.summary(tab) == .idle)
    }

    @Test func rowAndTabFollowTheMergedStatus() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(try tabs(store, workspace: "beta").first)
        tab.setAgent(AgentStatus(surface: 1, state: .working))
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let row = try #require(SidebarMapping.shared.sections(store.sidebarSections, machine: machine)[0].workspaces.first { $0.title == "beta" })
        #expect(row.activity == .busy)
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.isBusy)
        #expect(item.indicator == .busy)
    }
}
