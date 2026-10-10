import CmuxNextDesign
import CmuxNextLayout
import CoreGraphics
import Testing
@testable import CmuxNextApp
@testable import CmuxNextLayout

/// `debug.dock` (nxdog35 preflight): a top-level `docks` list with each
/// dock's window, column, edge, mode, frame and rim, so a test finds the dock
/// without walking the per-window report.
@MainActor
struct DebugDockReportTests {
    @Test func theTopLevelDocksListCarriesEdgeColumnFrameAndRim() {
        let column = DockLayoutReport.Column(
            column: ColumnID("c9"), dock: DockColumn(edge: .right, mode: .docked),
            frameInWindow: CGRect(x: 550, y: 0, width: 350, height: 600),
            coverInWindow: CGRect(x: 544, y: 0, width: 356, height: 600),
            rimInWindow: CGRect(x: 546, y: 0, width: 8, height: 600),
            shownAsDock: true, panes: [PaneID("p1")], hasBackdrop: false)
        let docks = DebugDockColumns.docks(window: "w1", report: DockLayoutReport(
            columns: [column], stripMinX: 0, stripWidth: 544, uncoveredInWindow: CGRect(x: 0, y: 0, width: 544, height: 600),
            offset: 0, maxOffset: 0, contentWidth: 544, scrollbarMode: .auto, scrollbarShown: false,
            thumbInWindow: nil, bandInWindow: nil, paneOrder: []))
        #expect(docks.count == 1)
        guard case .object(let dock)? = docks.first else { Issue.record("not an object"); return }
        #expect(dock["window"] == .string("w1"))
        #expect(dock["column"] == .string("c9"))
        #expect(dock["edge"] == .string("right"))
        #expect(dock["mode"] == .string("docked"))
        #expect(dock["shown"] == .bool(true))
        #expect(dock["frame_in_window"] == .object(["x": .number(550), "y": .number(0), "width": .number(350), "height": .number(600)]))
        #expect(dock["rim_in_window"] == .object(["x": .number(546), "y": .number(0), "width": .number(8), "height": .number(600)]))
    }
}
