import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// The Chief's subagent workspaces read like any workspace (Leo 2026-10-21): their row shows the
/// task title on one line, with no `a14 · ` subagent id and no "Chief" second line. The id stays the Chief's own.
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
        #expect("a14 · Native workflows runtime".chiefTaskTitle == "Native workflows runtime")
        #expect("Native workflows runtime".chiefTaskTitle == "Native workflows runtime")
        // Only `a<digits> · ` at the start is an id.
        #expect("a · x".chiefTaskTitle == "a · x")
        #expect("ab1 · x".chiefTaskTitle == "ab1 · x")
        #expect("Fix a1 · x".chiefTaskTitle == "Fix a1 · x")
        #expect("a3 · ".chiefTaskTitle == nil)
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



    /// The Chief's daemon holding one subagent workspace `name` (`ws_…0011` in session
    /// `cmux-chief-6b68ac4a`), an agent chat in it when `harness` is set, pinned to the top.
    static func pinnedChiefWorkspace(_ name: String, harness: String?, pinned: Bool = false) -> (SidebarLayoutDocument, WorkspaceLayoutRefs, LayoutItemRef) {
        _ = NSApplication.shared
        let machines = MachineRegistry(local: DaemonService())
        let session = ServerMachineSession(reach: chief, binary: nil, paths: .init(root: URL(fileURLWithPath: "/private/tmp/cn-chief-top-unused")),
                                           environment: { [:] }, localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        machines.add(session)
        var tab = TabSnapshot(surface: 1, kind: harness == nil ? .pty : .conversation, cwd: nil)
        tab.conversation = harness.map { ConversationTabRef(agentSession: AgentSessionRef(host: "install:chief-top", session: "s1", harness: $0)) }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        let workspace = WorkspaceSnapshot(id: 1, key: nil, resourceID: "ws_00000000000000000000000000000011", name: name, screens: [screen], pinned: pinned)
        session.daemon.store.apply(snapshot: DaemonTree(registryID: "cmux-chief-6b68ac4a", workspaces: [workspace]))
        let ref = LayoutItemRef.workspace("cmux-chief-6b68ac4a:ws_00000000000000000000000000000011")
        let top = LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [LayoutItem(id: LayoutItemID("itm_pin"), ref: ref)])
        return (SidebarLayoutDocument(sections: [top]), WorkspaceLayoutRefs(machines: machines), ref)
    }

    /// Leo 2026-10-22, of a pinned Chief workspace drawn as a grey "A" tile over
    /// "a11 · Land pet dock PRs": "why is this a thing at the top". The top band reads the
    /// workspace on its own machine, so it shows the task title. A workspace with no icon of its
    /// own stays text only, agent or not (WORKSPACE-ROWS-NO-DEFAULT-ICON); its tile's letter now
    /// comes from the task title.
    @Test(arguments: ["claude", nil] as [String?])
    func aPinnedChiefWorkspaceShowsItsTaskTitle(harness: String?) throws {
        let (layout, refs, ref) = Self.pinnedChiefWorkspace("a11 · Land pet dock PRs", harness: harness)
        let info = try #require(SidebarWorkspaceItems.workspaceInfos(layout, refs: refs)[ref])
        #expect(info.title == "Land pet dock PRs")
        #expect(info.textOnly)
        #expect(info.brand == nil)
        // The letter a tile draws (`SidebarItemRowView.glyphImage`: the caption, else the title).
        #expect((info.caption ?? info.title).first == "L")
    }
}
