@testable import CmuxNextSidebar
import Testing

/// A chat moving to another machine (`SidebarChatMove`): its row goes to that machine's section with the step and
/// bar, keeps its id (so the list slides it there), and stays put when the machine is unknown or not listed.
@Suite struct SidebarChatMoveTests {
    private static let cloud = MachineID("m-1")

    private static func sections() -> [SidebarSection] {
        let here = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let dev = SidebarMachine(id: cloud, name: "dev", kind: .cloud)
        let chat = SidebarWorkspace(id: WorkspaceID("chat"), title: "Fix the build")
        let grouped = SidebarWorkspace(id: WorkspaceID("grouped"), title: "In a group")
        var group = SidebarGroup(id: GroupID("g"), name: "G", color: .grey, isCollapsed: false, workspaces: [])
        group.setMembers([.workspace(grouped)])
        return [
            SidebarSection(kind: .machine(here), nodes: [.workspace(chat), .group(group)]),
            SidebarSection(kind: .machine(dev), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("there"), machineID: cloud, title: "There"))]),
        ]
    }

    @Test func theRowTravelsToTheMachineSayingTheStep() throws {
        let move = SidebarChatMove(workspace: WorkspaceID("chat"), machine: Self.cloud, line: "2 of 4 · Copying the folder", fraction: 0.4)
        let moved = SidebarChatMove.applying([move], to: Self.sections(), moving: "Moving…")
        #expect(moved[0].workspaces.map(\.id.rawValue) == ["grouped"])
        #expect(moved[1].workspaces.map(\.id.rawValue) == ["there", "chat"])
        let row = try #require(moved[1].workspaces.last)
        #expect(row.machineID == Self.cloud)
        #expect(row.status == "2 of 4 · Copying the folder")
        #expect(row.progress == SidebarProgress(value: 0.4))
        #expect(row.rowState.isPending)
        #expect(!row.isClosable)
    }

    @Test func beforeTheFirstLineItSaysMovingWithAnOpenBar() throws {
        let move = SidebarChatMove(workspace: WorkspaceID("chat"), machine: Self.cloud, line: nil, fraction: nil)
        let row = try #require(SidebarChatMove.applying([move], to: Self.sections(), moving: "Moving…")[1].workspaces.last)
        #expect(row.status == "Moving…")
        #expect(row.progress == SidebarProgress(value: nil))
    }

    @Test func noMachineOrAnUnlistedOneKeepsTheRowInPlaceShowingTheMove() throws {
        for machine in [nil, MachineID("not-listed")] {
            let move = SidebarChatMove(workspace: WorkspaceID("grouped"), machine: machine, line: "1 of 4", fraction: 0.1)
            let shown = SidebarChatMove.applying([move], to: Self.sections(), moving: "Moving…")
            #expect(shown.map { $0.workspaces.map(\.id.rawValue) } == [["chat", "grouped"], ["there"]])
            let row = try #require(shown[0].workspaces.last)
            #expect(row.status == "1 of 4")
            #expect(row.rowState.isPending)
        }
    }

    @Test func noMovesChangeNothing() {
        #expect(SidebarChatMove.applying([], to: Self.sections(), moving: "Moving…") == Self.sections())
    }
}
