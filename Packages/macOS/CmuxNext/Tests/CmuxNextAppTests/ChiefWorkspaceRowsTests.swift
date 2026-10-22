import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextRemote
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Chief's subagent workspaces read like any workspace (Leo 2026-10-21): their row shows the
/// task title on one line, with no `a14 · ` subagent id and no "Chief" second line, and the hover
/// card says "Started by Chief". The id stays the Chief's own.
@MainActor
struct ChiefWorkspaceRowsTests {
    static let chief = try! ServerReach.localChief(homeID: "6b68ac4a", socket: "/tmp/chief.sock", name: "Chief")

    @Test func theMachineIDRuleMatchesTheLocalChiefReach() throws {
        #expect(CmuxNextSidebar.MachineID(Self.chief.machineID).isLocalChief)
        #expect(!CmuxNextSidebar.MachineID.local.isLocalChief)
        let server = try ServerReach(hostID: "host_7f3a0001", installID: "inst_7f3a0001", name: "mini", route: .unix("/tmp/s.sock"))
        #expect(!server.isLocalChief)
        #expect(!CmuxNextSidebar.MachineID(server.machineID).isLocalChief)
    }

    @Test func theTaskTitleDropsOnlyASubagentID() {
        #expect(ChiefWorkspaceName.taskTitle("a14 · Native workflows runtime") == "Native workflows runtime")
        #expect(ChiefWorkspaceName.taskTitle("Native workflows runtime") == "Native workflows runtime")
        // Only `a<digits> · ` at the start is an id.
        #expect(ChiefWorkspaceName.taskTitle("a · x") == "a · x")
        #expect(ChiefWorkspaceName.taskTitle("ab1 · x") == "ab1 · x")
        #expect(ChiefWorkspaceName.taskTitle("Fix a1 · x") == "Fix a1 · x")
        #expect(ChiefWorkspaceName.taskTitle("a3 · ") == nil)
    }

    static func workspace(_ name: String) throws -> WorkspaceModel {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, activeTab: 0, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    @Test func aChiefWorkspaceRowShowsItsTaskTitle() throws {
        let workspace = try Self.workspace("a14 · Native workflows runtime")
        let chief = SidebarMapping.shared.row(workspace, machine: CmuxNextSidebar.MachineID(Self.chief.machineID))
        #expect(chief.title == "Native workflows runtime")
        // Another machine's workspace keeps the name it was given.
        #expect(SidebarMapping.shared.row(workspace, machine: CmuxNextSidebar.MachineID.local).title == "a14 · Native workflows runtime")
    }

    @Test func aChiefWorkspaceRowHasNoMachineLine() {
        func label(_ machine: SidebarMachine) -> String? {
            let section = SidebarSection(kind: .machine(machine), nodes: [])
            var options = SidebarLayoutOptions()
            options.flattensMachines = true
            return SidebarLayout.machineLabel(section, options: options)
        }
        #expect(label(SidebarMachine(id: CmuxNextSidebar.MachineID(Self.chief.machineID), name: "Chief", kind: .server)) == nil)
        #expect(label(SidebarMachine(id: CmuxNextSidebar.MachineID("server-host_7f3a0001"), name: "mini", kind: .server)) == "mini")
    }

    @Test func aChiefWorkspacesHoverCardSaysWhoStartedIt() throws {
        let id = CmuxNextSidebar.MachineID(Self.chief.machineID)
        let workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("w1"), machineID: id, title: "Native workflows runtime")
        let machine = SidebarMachine(id: id, name: "Chief", kind: .server)
        let card = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date())
        let fact = try #require(card.facts.first { $0.kind == "machine" })
        #expect(fact.text == CmuxNextSidebar.Strings.startedByChief)
        #expect(card.title == "Native workflows runtime")
    }
}
