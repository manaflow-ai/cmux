import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The detector for cmuxterm-hq#13493 item 2 (Leo 2026-11-18: "Why should non visible thing even affect the renderer
/// thread anyways?"): a change that is not one row's insert or close laid out every row and rebuilt every row cache, so
/// its cost grew with the sessions (10,789 for Leo). A batch of adds and closes, a move to another computer's list, and
/// a row whose new content changes its height now splice: the rows laid out (`layout_rows`) are the changed rows, and
/// the row caches take nothing again (`row_cache_rows`), at 100 rows as at 10,789. Each case also checks the shown
/// layout is exactly the full one, so a splice never draws what a full layout would not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .closesItsWindows)
struct SidebarStructuralSpliceTests {
    typealias Insert = SidebarCreateInsertScalingTests
    typealias Close = SidebarCloseMoveSpliceTests

    static let sizes = [100, 10_789]

    static func batchRow(_ i: Int) -> SidebarNode { .workspace(SidebarWorkspace(id: WorkspaceID("ci-batch-\(i)"), title: "batch \(i)")) }

    /// `nodes` with a new row at each of `at` (indices in the result, ascending).
    static func adding(_ at: [Int], to nodes: [SidebarNode]) -> [SidebarNode] {
        var result = nodes
        for (i, k) in at.enumerated() { result.insert(batchRow(i), at: k) }
        return result
    }

    @Test func aBatchOfAddsAndClosesLaysOutOnlyItsRowsAt100Or10789() {
        var laidOut: [Int: [Int]] = [:]
        for count in Self.sizes {
            let h = Insert.make(count)
            defer { h.window.close() }
            let added = Self.adding([1, count / 2, count + 1], to: h.rows)
            let adds = Close.set(h, added)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "rows \(count): the shown layout after the adds is not the model's")
            #expect(h.sidebar.list.workspaces[WorkspaceID("ci-batch-2")] != nil, "rows \(count): an added row is not cached")
            let closes = Close.set(h, h.rows)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "rows \(count): the shown layout after the closes is not the model's")
            #expect(h.sidebar.list.workspaces[WorkspaceID("ci-batch-0")] == nil, "rows \(count): a closed row is still cached")
            laidOut[count] = [adds["layout_rows"] ?? 0, closes["layout_rows"] ?? 0]
            #expect(adds["row_cache_rows"] ?? 0 == 0 && closes["row_cache_rows"] ?? 0 == 0,
                    "rows \(count): the batch rebuilt every row cache: \(adds) \(closes)")
        }
        #expect(laidOut[100] == [3, 3], "rows laid out per batch of three adds, then three closes: \(laidOut)")
        #expect(laidOut[100] == laidOut[10_789], "rows laid out per batch grow with the list: \(laidOut)")
    }

    @Test func aRowWhoseHeightChangesLaysOutOneRowAt100Or10789() throws {
        var laidOut: [Int: [Int]] = [:]
        for count in Self.sizes {
            let h = Insert.make(count)
            defer { h.window.close() }
            let key = SidebarRowKey.workspace(WorkspaceID("ci-5"))
            let before = try #require(h.sidebar.list.displayed.row(for: key)).height
            var counts: [Int] = []
            for reported in [true, false] {
                _ = SidebarPerfCounters.report(reset: true)
                let row = SidebarStructuralChangeBenchTests.statusRow(WorkspaceID("ci-5"), title: "workspace 5", reported: reported)
                #expect(h.model.patchWorkspaces([row]))
                h.sidebar.renderNow()
                let report = SidebarPerfCounters.report(reset: true)
                counts.append(report["layout_rows"] ?? 0)
                #expect(report["row_cache_rows"] ?? 0 == 0, "rows \(count): a height change rebuilt every row cache: \(report)")
                let shown = try #require(h.sidebar.list.displayed.row(for: key))
                #expect(reported ? shown.height > before : shown.height == before, "rows \(count): the row's height did not follow its status")
                #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "rows \(count), reported \(reported): the shown layout is not the model's")
            }
            laidOut[count] = counts
        }
        #expect(laidOut[100] == [1, 1], "rows laid out per height change: \(laidOut)")
        #expect(laidOut[100] == laidOut[10_789], "rows laid out per height change grow with the list: \(laidOut)")
    }

    /// A row moved to another computer's list is one row out and one row in, not a full layout.
    @Test func aMoveToAnotherSectionLaysOutTwoRowsAt100Or10789() {
        var laidOut: [Int: Int] = [:]
        for count in Self.sizes {
            let h = Insert.make(count)
            defer { h.window.close() }
            let other = SidebarMachine(id: MachineID("ssh-ci-remote"), name: "remote", kind: .ssh)
            let remote = (0..<3).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ci-r\($0)"), title: "remote \($0)")) }
            var local = h.rows
            h.model.setSections(Insert.sections(local) + [SidebarSection(kind: .machine(other), nodes: remote)])
            h.sidebar.renderNow()
            let moved = local.remove(at: 4)
            _ = SidebarPerfCounters.report(reset: true)
            h.model.setSections(Insert.sections(local) + [SidebarSection(kind: .machine(other), nodes: [remote[0], moved, remote[1], remote[2]])])
            h.sidebar.renderNow()
            laidOut[count] = SidebarPerfCounters.report(reset: true)["layout_rows"] ?? 0
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "rows \(count): the row moved to the remote section")
        }
        #expect(laidOut[100] == 2, "rows laid out per move to another list: \(laidOut)")
        #expect(laidOut[100] == laidOut[10_789], "rows laid out per move grow with the list: \(laidOut)")
    }

    /// A batch draws what a full layout draws wherever its rows land: together at the top, side by side in the middle,
    /// at the end, around the group and above "Done (1)", with closes in the same set, and grouped by computer.
    @Test(arguments: [[0, 1], [3, 4, 5], [0, 13], [10, 12], [2, 11, 14]])
    func aBatchShowsTheFullLayout(at indices: [Int]) {
        for byComputer in [false, true] {
            let h = Insert.make(10, extra: Close.extra(), groupsByComputer: byComputer)
            defer { h.window.close() }
            var nodes = Self.adding(indices, to: h.rows)
            Close.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "adds at \(indices), by computer \(byComputer)")
            // Two closes and an add in one set.
            nodes.removeAll { if case let .workspace(ws) = $0 { ws.id == WorkspaceID("ci-batch-0") || ws.id == WorkspaceID("ci-7") } else { false } }
            nodes.insert(Self.batchRow(9), at: 2)
            Close.set(h, nodes)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "closes and an add after \(indices), by computer \(byComputer)")
            Close.set(h, h.rows)
            #expect(h.sidebar.list.displayed == Insert.fullLayout(h), "back to the first rows after \(indices), by computer \(byComputer)")
        }
    }

    /// The detector finds adds and closes of loose rows only.
    @Test func theBatchIsFoundOnlyForLooseAddsAndCloses() {
        let ws = { (id: String) in SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID(id), title: id)) }
        let (a, b, c, d, e) = (ws("a"), ws("b"), ws("c"), ws("d"), ws("e"))
        let s = { (nodes: [SidebarNode]) in Insert.sections(nodes) }
        #expect(SidebarSection.looseEdits(from: s([a, b, c]), to: s([d, a, e, b, c]))?.first?.inserted == [0, 2])
        #expect(SidebarSection.looseEdits(from: s([a, b, c, d]), to: s([b, d]))?.first?.removed == [0, 2])
        #expect(SidebarSection.looseEdits(from: s([a, b, c]), to: s([e, b, d]))?.first.map { [$0.removed, $0.inserted] } == [[0, 2], [0, 2]])
        // An order change, or a row closed and added back in the same list, is no batch.
        #expect(SidebarSection.looseEdits(from: s([a, b, c]), to: s([c, b, a])) == nil)
        #expect(SidebarSection.looseEdits(from: s([a, b, c]), to: s([b, c, a, d])) == nil)
        #expect(SidebarSection.looseEdits(from: s([a, b]), to: s([a, b])) == nil)
    }

    /// The session tree's agents' states alone (a lane's turn starting or ending) draw no row unless a folded parent
    /// rolls them up: they lay nothing out (the render compared every session's state and laid every row out).
    @Test func aSessionTreeStatesChangeLaysOutNoRow() {
        let h = Insert.make(100)
        defer { h.window.close() }
        let tree = SidebarSessionTree.shared
        let saved = tree.state
        defer { tree.state = saved; h.sidebar.renderNow() }
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("ci-3"): WorkspaceID("ci-2")], states: [WorkspaceID("ci-3"): .running])
        h.sidebar.renderNow()
        guard tree.collapsed.isEmpty else { return } // a fold this host's defaults kept rolls the states up
        _ = SidebarPerfCounters.report(reset: true)
        tree.state?.states[WorkspaceID("ci-3")] = .idle
        h.sidebar.renderNow()
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] ?? 0 == 0, "a states change reloaded the list: \(counts)")
        #expect(counts["layout_rows"] ?? 0 == 0, "a states change laid out rows: \(counts)")
        // The parents changing is the tree's shape: the list lays out again.
        tree.state?.parents = [:]
        h.sidebar.renderNow()
        #expect(SidebarPerfCounters.report(reset: true)["list_reloads"] ?? 0 > 0, "a parent change did not reload the list")
    }
}
