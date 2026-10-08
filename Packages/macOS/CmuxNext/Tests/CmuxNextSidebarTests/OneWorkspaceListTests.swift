import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// `sidebar.groupByComputer` off, the default (Lawrence 2026-10-08, cx-plf5:
/// "default sidebar should not have computers. it should just be single list
/// of workspaces"): one "Projects" header over the whole list (as with one
/// computer today) and no computer header, no gap between computers, an
/// empty computer shows nothing, and a workspace of another computer names it
/// on its second line. Pinned and user groups stay.
struct OneWorkspaceListTests {
    static func sections(cloudNodes: [SidebarNode]) -> [SidebarSection] {
        [
            SidebarSection(kind: .pinned, nodes: [.workspace(w("p1"))]),
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .workspace(w("a")),
                .group(SidebarGroup(id: g1, name: "G1", color: .purple, workspaces: [w("g1")])),
            ]),
            SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "devbox", kind: .cloud)), nodes: cloudNodes),
        ]
    }

    static func layout(_ sections: [SidebarSection], grouped: Bool) -> SidebarLayout {
        var o = SidebarLayoutOptions()
        o.showsSoleMachineHeader = true
        o.flattensMachines = !grouped
        return SidebarLayout.make(sections: sections, metrics: .standard, options: o)
    }

    @Test func oneListHasOneProjectsHeaderAndNoComputerHeaders() {
        let rows = Self.layout(Self.sections(cloudNodes: [.workspace(w("c", cloud))]), grouped: false).rows
        #expect(rows.map(\.key) == [.section(.pinned), .workspace(id("p1")), .section(local), .workspace(id("a")), .group(g1),
                                    .workspace(id("g1")), .workspace(id("c"))])
        #expect(rows.first { $0.key == .section(local) }?.titlesProjects == true)
    }

    @Test func collapsingTheProjectsHeaderFoldsTheWholeList() {
        var sections = Self.sections(cloudNodes: [.workspace(w("c", cloud))])
        sections[1].isCollapsed = true
        #expect(Self.layout(sections, grouped: false).rows.map(\.key) == [.section(.pinned), .workspace(id("p1")), .section(local)])
    }

    @Test func groupingByComputerKeepsTheHeaders() {
        let keys = Self.layout(Self.sections(cloudNodes: [.workspace(w("c", cloud))]), grouped: true).rows.map(\.key)
        #expect(keys.contains(.section(local)))
        #expect(keys.contains(.section(cloudSection)))
    }

    @Test func aWorkspaceOfAnotherComputerNamesIt() throws {
        let rows = Self.layout(Self.sections(cloudNodes: [.workspace(w("c", cloud))]), grouped: false).rows
        let remote = try #require(rows.first { $0.key == .workspace(id("c")) })
        let mine = try #require(rows.first { $0.key == .workspace(id("a")) })
        #expect(remote.content?.detail == "devbox")
        #expect(mine.content?.detail == nil, "this Mac's workspaces name no computer")
        let grouped = Self.layout(Self.sections(cloudNodes: [.workspace(w("c", cloud))]), grouped: true).rows
        #expect(grouped.first { $0.key == .workspace(id("c")) }?.content?.detail == nil, "the header names it instead")
    }

    @Test func anEmptyComputerShowsNothingInOneList() {
        let keys = Self.layout(Self.sections(cloudNodes: []), grouped: false).rows.map(\.key)
        #expect(!keys.contains(.emptySection(cloudSection)))
        #expect(keys.last == .workspace(id("g1")))
    }

    @Test func consecutiveComputersReadAsOneList() throws {
        let rows = Self.layout(Self.sections(cloudNodes: [.workspace(w("c", cloud))]), grouped: false).rows
        let last = try #require(rows.first { $0.key == .workspace(id("g1")) })
        let remote = try #require(rows.first { $0.key == .workspace(id("c")) })
        let m = SidebarLayoutMetrics.standard
        #expect(abs(remote.y - (last.y + last.height + m.rowSpacing + m.groupBottomPadding)) < 0.001, "no section gap between computers")
    }
}
