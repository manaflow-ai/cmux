@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30, of a sidebar row titled "claude-sr2-coord" over "local · claude-sr2-coord": "and
/// yes ofc remove the second line". A workspace row has no second line of its own: not the computer,
/// its folder, a Cloud stage or the description. Its second line is only the elements the person turned
/// on in Settings (`sidebar.workspaceRow`, none by default).
@MainActor struct SidebarNoSecondLineTests {
    private let remote = SidebarMachine(id: MachineID("local"), name: "local", kind: .ssh)

    @Test func aRowOnAnotherComputerDrawsNoSecondLineByDefault() {
        var ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: remote.id, title: "claude-sr2-coord", directory: "claude-sr2-coord")
        ws.workspaceDescription = "Coordinate the GUI push"
        ws.stage = "Starting"
        let content = WorkspaceRowContent(ws, preferences: .defaults, machine: remote.name)
        #expect(content.detail == nil, "the row drew a second line: \(content.detail ?? "")")
    }

    @Test func elementsThePersonTurnedOnStillDraw() {
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: remote.id, title: "app", directory: "~/code/app", branch: "main")
        let on = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.directory, .branch])))
        let content = WorkspaceRowContent(ws, preferences: on, machine: remote.name)
        #expect(content.detail == "~/code/app · main", "a turned-on element lost its line, or the computer came back: \(content.detail ?? "")")
    }

    @Test func anExpandedRowKeepsItsOwnMetaLine() {
        var ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: remote.id, title: "app")
        ws.stage = "Starting"
        let content = WorkspaceRowContent(expanded: ws, now: Date(), machine: remote.name)
        #expect(content.meta?.contains(remote.name) == true, "the expanded row lost the computer on its meta line")
    }
}
