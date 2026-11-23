import CmuxNextBridge
import CmuxNextSidebar
import Testing

struct WorkspaceGapTests {
    private func sections(_ keys: [String], grouped: Bool) -> [SidebarRowSection] {
        let rows = keys.map { SidebarWorkspace(id: SidebarWorkspaceID($0), title: $0) }
        let nodes = grouped ? [SidebarNode.group(SidebarGroup(id: GroupID("g"), name: "group", workspaces: rows))] : rows.map(SidebarNode.workspace)
        return [SidebarRowSection(kind: .machine(SidebarMachine(id: .local, name: "local", kind: .local)), nodes: nodes)]
    }

    @Test(arguments: [false, true])
    func savedGapFollowsItsNeighborsAfterEarlierRowsArrive(grouped: Bool) throws {
        let position = DropPosition(section: .machine(.local), group: grouped ? GroupID("g") : nil, index: 1)
        let gap = try #require(WorkspaceGap(position, in: sections(["k1", "k2"], grouped: grouped)))
        let current = sections(["new", "k0", "k1", "k2"], grouped: grouped)
        let resolved = try #require(WorkspaceSlot.gap(gap).position(moving: ["new"], section: .machine(.local), in: current))
        #expect(resolved.index == 2) // after k1, still before k2
        #expect(resolved.group == position.group)
    }

    @Test func aRemovedNextNeighborUsesThePreviousNeighbor() throws {
        let gap = try #require(WorkspaceGap(DropPosition(section: .machine(.local), index: 1), in: sections(["k1", "k2"], grouped: false)))
        #expect(gap.position(moving: ["new"], in: sections(["new", "k0", "k1"], grouped: false))?.index == 2)
        #expect(gap.position(moving: ["new"], in: sections(["new", "k0"], grouped: false)) == nil)
    }

    /// The gap below a container's last row, after that row closes, does not resolve (to index 0 or anywhere): a
    /// new workspace made from that row falls on to the gap above it, then its group's end (NewWorkspaceDefaultSlot).
    @Test(arguments: [false, true])
    func theGapBelowALastRowThatClosedDoesNotResolve(grouped: Bool) throws {
        let gap = try #require(WorkspaceGap(DropPosition(section: .machine(.local), group: grouped ? GroupID("g") : nil, index: 2),
                                            in: sections(["k1", "k2"], grouped: grouped)))
        #expect(gap.position(moving: ["new"], in: sections(["new", "k1"], grouped: grouped)) == nil)
    }

    @Test func aRemovedContainerCannotTurnIntoALooseDrop() throws {
        let gap = try #require(WorkspaceGap(DropPosition(section: .machine(.local), group: GroupID("g"), index: 1),
                                            in: sections(["k1", "k2"], grouped: true)))
        #expect(gap.position(moving: ["new"], in: sections(["new", "k1", "k2"], grouped: false)) == nil)
    }
}
