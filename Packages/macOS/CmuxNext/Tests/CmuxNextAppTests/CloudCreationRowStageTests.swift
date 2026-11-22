import CmuxNextDesign
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// cx-lu8f follow-up (coordinator, 2026-10-09): the sidebar row is where
/// Lawrence looked when New Cloud Workspace seemed broken, and it showed
/// only its title and machine. A starting Cloud machine's row shows its
/// stage in the always-visible machine label, whatever `sidebar.workspaceRow`
/// shows; the normal label returns when the workspace is ready.
@MainActor struct CloudCreationRowStageTests {
    private func row(_ creations: CloudCreations) throws -> (SidebarWorkspace, CloudMachineCreation) {
        let creation = creations.begin(window: "w1")
        let sections = CloudCreationRows.adding(creations.shown(in: "w1"), to: [])
        let row = try #require(sections.flatMap(\.workspaces).first { $0.id.rawValue == creation.rowID })
        return (row, creation)
    }

    @Test func aStartingCloudRowShowsItsStageWithTheMachineLabel() throws {
        let (row, _) = try row(CloudCreations())
        #expect(row.stage == CloudStrings.stage(.requesting))
        let content = WorkspaceRowContent(row, preferences: .defaults, machine: "graceful-lemon-dolphin")
        #expect(content.detail == "graceful-lemon-dolphin" + WorkspaceRowContent.separator + CloudStrings.stage(.requesting))
        // Grouped by computer there is no machine label: the stage alone.
        #expect(WorkspaceRowContent(row, preferences: .defaults, machine: nil).detail == CloudStrings.stage(.requesting))
    }

    @Test func aFailedCreationSaysSoInTheLabel() throws {
        let creations = CloudCreations()
        let (_, creation) = try row(creations)
        creation.fail(ActionFailure(message: "quota"))
        let failed = try #require(CloudCreationRows.adding(creations.shown(in: "w1"), to: []).flatMap(\.workspaces).first)
        #expect(failed.stage == CloudStrings.stage(.failed("quota")))
    }

    @Test func otherRowsKeepTheirLabel() {
        let ws = SidebarWorkspace(id: WorkspaceID("a"), machineID: MachineID("vm-1"), title: "a")
        #expect(ws.stage == nil)
        #expect(WorkspaceRowContent(ws, preferences: .defaults, machine: "vm").detail == "vm")
    }
}
