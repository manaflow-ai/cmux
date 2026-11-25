import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// An agent that opens a session's workspace without `group` (`cmux agent open SESSION`,
/// `cmux agents chat new`, the MCP `app_agent_open`) puts it in its own chat's sidebar group,
/// right below its own row, instead of wherever the window happens to show (Leo, 2026-10-30:
/// "there are still hundreds of random ass sessions that i have 0 clue what are for plus you
/// didnt do these groups well"). A `group`, a person's open, or a loose parent keeps Cmd-N's placement.
@MainActor @Suite(.serialized)
struct AgentSessionParentGroupTests {
    @Test func aSpawnWithoutGroupJoinsItsParentsGroup() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let group = WorkspaceGroupID(rawValue: "g-lanes")
        // Sorted keys: "a-parent" is workspaces[0], the grouped one; "b-loose" and "c-child" are loose.
        func tree(_ keys: [String]) -> DaemonTree {
            var value = PlacementStaleRowsTests.tree(keys, personal: keys)
            value.personal?.groups = [WorkspaceGroupSnapshot(id: group, name: "lanes", profile: .defaultProfile)]
            value.personal?.workspaces[0].group = group
            return value
        }
        let keys = ["a-parent", "b-loose", "c-child"]
        store.apply(snapshot: tree(keys))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: keys))
        defer { controller.teardown(); controller.window?.close() }
        let sidebar = controller.sidebar
        sidebar.resync()
        let sections = WindowManager.placementSections(in: sidebar)

        let slot = WorkspaceSlot.belowGrouped("a-parent", in: sidebar.model.sections)
        #expect(slot == .below("a-parent"))
        let machine = try #require(services.machines.daemon(forWorkspace: "c-child")?.machineID)
        let section = CmuxNextSidebar.SectionID.machine(CmuxNextSidebar.MachineID(machine))
        let position = try #require(slot?.position(moving: ["c-child"], section: section, in: sections))
        #expect(position.group?.rawValue == group.rawValue)

        // A loose parent, or one the sidebar does not list: Cmd-N's placement, unchanged.
        #expect(WorkspaceSlot.belowGrouped("b-loose", in: sidebar.model.sections) == nil)
        #expect(WorkspaceSlot.belowGrouped("not-listed", in: sidebar.model.sections) == nil)
    }
}
