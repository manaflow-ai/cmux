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
        #expect(row.rowState == .moving && row.rowState.isPending)
        #expect(!row.isClosable)
    }

    @Test func beforeTheFirstLineItSaysMovingWithAnOpenBar() throws {
        let move = SidebarChatMove(workspace: WorkspaceID("chat"), machine: Self.cloud, line: nil, fraction: nil)
        let row = try #require(SidebarChatMove.applying([move], to: Self.sections(), moving: "Moving…")[1].workspaces.last)
        #expect(row.status == "Moving…")
        #expect(row.progress == SidebarProgress(value: nil))
    }

    @Test func noMachineOrAnUnlistedOneKeepsTheRowInPlaceAndWorkingShowingTheMove() throws {
        for machine in [nil, MachineID("not-listed")] {
            let move = SidebarChatMove(workspace: WorkspaceID("grouped"), machine: machine, line: "1 of 4", fraction: 0.1)
            let shown = SidebarChatMove.applying([move], to: Self.sections(), moving: "Moving…")
            #expect(shown.map { $0.workspaces.map(\.id.rawValue) } == [["chat", "grouped"], ["there"]])
            let row = try #require(shown[0].workspaces.last)
            #expect(row.status == "1 of 4")
            #expect(!row.rowState.isPending && row.isClosable) // its other tabs stay: the row keeps working
        }
    }

    /// The sidebar document's drag (the normal one): a lone chat's row over another machine it can move to opens a
    /// top-level slot there, though the document refuses the place; nowhere else.
    @Test func theDocumentDragOffersTheChatsMachinesOnly() {
        let dev = SectionID.machine(Self.cloud)
        let header = SidebarRow(key: .section(dev), y: 0, height: 28, section: dev, siblingIndex: 0,
                                isLastInGroup: true, isCollapsed: false, childCount: 1)
        let member = SidebarRow(key: .workspace(WorkspaceID("there")), y: 28, height: 28, section: dev, siblingIndex: 0,
                                isLastInGroup: true, isCollapsed: false, childCount: 0)
        let grouped = SidebarRow(key: .workspace(WorkspaceID("deep")), y: 56, height: 28, section: dev, group: GroupID("g"),
                                 siblingIndex: 0, isLastInGroup: true, isCollapsed: false, childCount: 0)
        let rows = ["h": header, "r": member, "g": grouped]
        func hit(_ key: String, _ zone: SidebarDragGeometry.Zone = .after, refused: Bool = true) -> SidebarDragGeometry.Hit {
            let slot = SidebarDragGeometry.Slot(key: key, item: key, section: "m", frame: .zero, kind: .row)
            return SidebarDragGeometry.Hit(slot: slot, zone: zone, target: refused ? nil : SidebarDocTarget(section: "m", parent: nil, after: key),
                                           refusal: refused ? "cross_machine" : nil)
        }
        let targets = [Self.cloud]
        #expect(SidebarDocDrag.chatMove(hit("h"), rows: rows, targets: targets) == DropPosition(section: dev, index: 0))
        #expect(SidebarDocDrag.chatMove(hit("r"), rows: rows, targets: targets) == DropPosition(section: dev, index: 1))
        #expect(SidebarDocDrag.chatMove(hit("r"), rows: rows, targets: []) == nil) // no chat to move: refused as before
        #expect(SidebarDocDrag.chatMove(hit("r"), rows: rows, targets: [.local]) == nil) // not one of its machines
        #expect(SidebarDocDrag.chatMove(hit("r", refused: false), rows: rows, targets: targets) == nil) // the document takes it
        #expect(SidebarDocDrag.chatMove(hit("g"), rows: rows, targets: targets) == nil) // inside a group
    }

    @Test func noMovesChangeNothing() {
        #expect(SidebarChatMove.applying([], to: Self.sections(), moving: "Moving…") == Self.sections())
    }
}
