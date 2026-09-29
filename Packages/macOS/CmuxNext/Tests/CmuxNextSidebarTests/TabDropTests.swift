import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// External tab drags: into a row, a new-workspace gap, or a collapsed group.
@Suite struct TabDropMath {
    let sections = fixture()
    var base: SidebarLayout { SidebarLayout.make(sections: sections, metrics: .standard) }

    func resolve(_ key: SidebarRowKey, _ fraction: CGFloat, machine: MachineID? = .local) -> SidebarTabDrop? {
        let row = base.row(for: key)!
        return DropResolver.resolveTabDrop(y: row.y + row.height * fraction, base: base, sections: sections, sourceMachine: machine)
    }

    @Test func middleOfRowMovesIntoWorkspace() {
        #expect(resolve(.workspace(id("b")), 0.5) == .intoWorkspace(id("b")))
        #expect(resolve(.workspace(id("g2")), 0.3) == .intoWorkspace(id("g2")))
    }

    @Test func rowEdgesOpenNewWorkspaceGap() {
        // b is section index 2.
        #expect(resolve(.workspace(id("b")), 0.1) == .newWorkspace(section: local, group: nil, index: 2))
        #expect(resolve(.workspace(id("b")), 0.9) == .newWorkspace(section: local, group: nil, index: 3))
        #expect(resolve(.workspace(id("g2")), 0.9) == .newWorkspace(section: local, group: g1, index: 2))
    }

    @Test func collapsedGroupMiddleCreatesInGroup() {
        #expect(resolve(.group(g2), 0.5) == .intoGroup(g2))
    }

    @Test func tabsStayOnTheirMachine() {
        #expect(resolve(.workspace(id("x")), 0.5) == nil)
        #expect(resolve(.workspace(id("x")), 0.5, machine: cloud) == .intoWorkspace(id("x")))
        // Pinned rows accept tabs from their own machine only; the pinned
        // area never hosts a new workspace.
        #expect(resolve(.workspace(id("p1")), 0.5) == .intoWorkspace(id("p1")))
        #expect(resolve(.workspace(id("p1")), 0.1) == nil)
    }

    @Test func gapResolutionIsStableWhileOpen() {
        guard case let .newWorkspace(section, group, index)? = resolve(.workspace(id("b")), 0.1) else {
            Issue.record("expected a gap"); return
        }
        var o = SidebarLayoutOptions()
        o.gap = DropPosition(section: section, group: group, index: index)
        o.gapHeight = SidebarLayoutMetrics.standard.rowHeight
        let displayed = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        // Inside the gap the resolver keeps the current proposal.
        #expect(DropResolver.baseY(forDisplayY: displayed.gapY! + 1, gapY: displayed.gapY, gapHeight: displayed.gapShift) == nil)
    }
}
