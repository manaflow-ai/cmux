import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-04: interaction cost stays constant as workspaces grow ("never ... acceptable ... linear time growth
/// degradation"). A close or a move of one loose workspace laid every row out again (sidebar-scroll-perf-DESIGN.md
/// cause 3). The list now takes the one row out of the layout it shows (`SidebarLayout.removeLoose`) and, for a move,
/// splices it back at its new place (`insertLoose`). Each case here checks the spliced layout is exactly the full one.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCloseMoveSpliceTests {
    typealias Insert = SidebarCreateInsertScalingTests

    /// 10 loose rows, a group (node 10), a loose row (11), a done row (12).
    static func extra() -> [SidebarNode] {
        let group = SidebarGroup(id: GroupID("ci-g"), name: "group", workspaces: [
            SidebarWorkspace(id: WorkspaceID("ci-g0"), title: "member 0"), SidebarWorkspace(id: WorkspaceID("ci-g1"), title: "member 1"),
        ])
        var done = SidebarWorkspace(id: WorkspaceID("ci-done"), title: "done")
        done.taskStatus = .done
        return [.group(group), .workspace(SidebarWorkspace(id: WorkspaceID("ci-after"), title: "after")), .workspace(done)]
    }

    /// Sets `nodes` as the model's one section, as the App's daemon mapping does, and draws it; the counters of it.
    @discardableResult
    static func set(_ h: Insert.Harness, _ nodes: [SidebarNode]) -> [String: Int] {
        _ = SidebarPerfCounters.report(reset: true)
        h.model.setSections(Insert.sections(nodes))
        h.sidebar.renderNow()
        return SidebarPerfCounters.report(reset: true)
    }

    @Test func closingARowLaysOutOneRowAt50Or2000() {
        var laidOut: [Int: Int] = [:]
        for count in [50, 2_000] {
            let h = Insert.make(count)
            defer { h.window.close() }
            var nodes = h.rows
            nodes.remove(at: 7)
            let counts = Self.set(h, nodes)
            laidOut[count] = counts["layout_rows"] ?? 0
            let list = h.sidebar.list
            #expect(list.displayed.row(for: .workspace(WorkspaceID("ci-7"))) == nil, "rows \(count): the closed row is listed")
            #expect(list.workspaces[WorkspaceID("ci-7")] == nil)
            #expect(list.displayed == Insert.fullLayout(h), "rows \(count): the shown layout is not the model's")
        }
        #expect(laidOut[50] == laidOut[2_000], "rows laid out per close grow with the list: \(laidOut)")
        #expect(laidOut[2_000] == 1, "rows laid out per close: \(laidOut)")
    }

    @Test func movingARowToTheTopLaysOutTwoRowsAt50Or2000() {
        var laidOut: [Int: Int] = [:]
        for count in [50, 2_000] {
            let h = Insert.make(count)
            defer { h.window.close() }
            var nodes = h.rows
            nodes.insert(nodes.remove(at: count - 1), at: 0)
            let counts = Self.set(h, nodes)
            laidOut[count] = counts["layout_rows"] ?? 0
            let list = h.sidebar.list
            #expect(list.displayed.row(for: .workspace(WorkspaceID("ci-\(count - 1)")))?.siblingIndex == 0)
            #expect(list.displayed == Insert.fullLayout(h), "rows \(count): the shown layout is not the model's")
        }
        #expect(laidOut[50] == laidOut[2_000], "rows laid out per move grow with the list: \(laidOut)")
        #expect(laidOut[2_000] == 2, "rows laid out per move: \(laidOut)")
    }

    /// A close draws what a full layout draws, wherever the row was: first, in the middle, the last loose row before
    /// the group, the loose row after it, the selected row (the selection moves on), and grouped by computer.
    @Test(arguments: [0, 1, 5, 9, 11])
    func aCloseShowsTheFullLayout(at index: Int) {
        for byComputer in [false, true] {
            let h = Insert.make(10, extra: Self.extra(), groupsByComputer: byComputer)
            defer { h.window.close() }
            var nodes = h.rows
            nodes.remove(at: index)
            let counts = Self.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "close at \(index), by computer \(byComputer)")
            // A plain close of an unselected loose row splices (one row), not a full layout.
            if !byComputer, index == 0 || index == 5 { #expect(counts["layout_rows"] == 1, "close at \(index): \(counts)") }
            // A second close right after the first takes its row out of the spliced layout.
            nodes.remove(at: 0)
            Self.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "second close after \(index), by computer \(byComputer)")
        }
    }

    /// A move draws what a full layout draws: up, down, past the group, to just before the done row, and back.
    @Test(arguments: [(9, 0), (0, 9), (2, 10), (11, 3), (4, 10)])
    func aMoveShowsTheFullLayout(from: Int, to: Int) {
        for byComputer in [false, true] {
            let h = Insert.make(10, extra: Self.extra(), groupsByComputer: byComputer)
            defer { h.window.close() }
            var nodes = h.rows
            nodes.insert(nodes.remove(at: from), at: to)
            Self.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "move \(from) -> \(to), by computer \(byComputer)")
            nodes.insert(nodes.remove(at: to), at: from)
            Self.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "move back \(to) -> \(from), by computer \(byComputer)")
        }
    }

    /// A move to another machine's section takes the row out of one and splices it into the other.
    @Test func aMoveToAnotherSectionShowsTheFullLayout() {
        let h = Insert.make(10)
        defer { h.window.close() }
        let other = SidebarMachine(id: MachineID("ssh-ci-remote"), name: "remote", kind: .ssh)
        let remote = [SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ci-r0"), title: "remote 0")),
                      .workspace(SidebarWorkspace(id: WorkspaceID("ci-r1"), title: "remote 1"))]
        var local = h.rows
        h.model.setSections(Insert.sections(local) + [SidebarSection(kind: .machine(other), nodes: remote)])
        h.sidebar.renderNow()
        let moved = local.remove(at: 4)
        h.model.setSections(Insert.sections(local) + [SidebarSection(kind: .machine(other), nodes: [remote[0], moved, remote[1]])])
        h.sidebar.renderNow()
        #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "the row moved to the remote section")
    }

    /// A close that leaves its section only an archived workspace draws the section's empty placeholder, as `make` does.
    @Test func closingTheLastDrawnRowShowsTheFullLayout() {
        var archived = SidebarWorkspace(id: WorkspaceID("ci-arch"), title: "archived")
        archived.isArchived = true
        let h = Insert.make(2, extra: [.workspace(archived)])
        defer { h.window.close() }
        var nodes = h.rows
        nodes.remove(at: 0)
        Self.set(h, nodes)
        #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "first close")
        nodes.remove(at: 0)
        Self.set(h, nodes)
        #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "the last drawn row closed")
    }

    /// The detectors find a close and a move, and nothing else.
    @Test func theSetsAreFoundOnlyForOneLooseRow() {
        let a = SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("a"), title: "a"))
        let b = SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("b"), title: "b"))
        let c = SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("c"), title: "c"))
        let s = { (nodes: [SidebarNode]) in Insert.sections(nodes) }
        #expect(SidebarSection.looseRemoval(from: s([a, b, c]), to: s([a, c]))?.node == 1)
        #expect(SidebarSection.looseRemoval(from: s([a, b, c]), to: s([c])) == nil)
        #expect(SidebarSection.looseMove(from: s([a, b, c]), to: s([c, a, b]))?.insertion.node == 0)
        #expect(SidebarSection.looseMove(from: s([a, b, c]), to: s([b, c, a]))?.removal.node == 0)
        #expect(SidebarSection.looseMove(from: s([a, b, c]), to: s([c, b, a])) == nil)
        #expect(SidebarSection.looseMove(from: s([a, b, c]), to: s([a, b, c])) == nil)
    }
}
