import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// A daemon-backed sidebar lists a machine's ungrouped workspaces before its
/// groups (cmux-tui keeps groups as a partition of one order and has no slot
/// for a loose workspace after a group). Dropping below the last row there
/// must target the end of the ungrouped rows, so the gap shows where the row
/// will really stay and the landing flight finds it.
@MainActor @Suite struct UngroupedFirstDropTests {
    func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [
            .workspace(w("a")),
            .workspace(w("b")),
            .group(SidebarGroup(id: g1, name: "G1", workspaces: [w("g1"), w("g2")])),
        ])]
    }

    @Test func dropBelowTheLastGroupTargetsTheEndOfTheUngroupedRows() throws {
        let sections = sections()
        var options = SidebarLayoutOptions()
        options.excludedWorkspaces = [id("a")]
        let base = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let below = base.totalHeight + 40
        let target = DropResolver.resolve(y: below, payload: .workspaces([id("a")]), base: base, sections: sections, ungroupedFirst: true)
        #expect(target == .position(DropPosition(section: local, index: 1)))
    }

    @Test func dropsIntoTheGroupAreUnchanged() throws {
        let sections = sections()
        var options = SidebarLayoutOptions()
        options.excludedWorkspaces = [id("a")]
        let base = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let g1Row = try #require(base.row(for: .workspace(id("g1"))))
        let target = DropResolver.resolve(y: g1Row.y + 1, payload: .workspaces([id("a")]), base: base, sections: sections, ungroupedFirst: true)
        #expect(target == .position(DropPosition(section: local, group: g1, index: 0)))
    }

    @Test func withoutTheRuleGroupsAndRowsInterleave() {
        let sections = sections()
        var options = SidebarLayoutOptions()
        options.excludedWorkspaces = [id("a")]
        let base = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let target = DropResolver.resolve(y: base.totalHeight + 40, payload: .workspaces([id("a")]), base: base, sections: sections)
        #expect(target == .position(DropPosition(section: local, index: 2)))
    }
}
