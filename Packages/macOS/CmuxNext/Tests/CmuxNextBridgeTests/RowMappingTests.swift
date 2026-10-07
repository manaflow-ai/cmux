import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// `columns[].rows` (`rows-v1`) reaches the layout as `LayoutColumn.rows`;
/// a column without rows keeps its single split tree.
struct RowMappingTests {
    private let paneIDs: [DaemonPaneID: LayoutPaneID] = [4: "p4", 5: "p5", 6: "p6"]

    private func map(_ snapshot: ColumnSnapshot) -> (LayoutColumn?, LayoutHandleMap) {
        var handles = LayoutHandleMap()
        let column = LayoutMapping.shared.column(snapshot, paneIDs: paneIDs, handles: &handles)
        return (column, handles)
    }

    @Test func rowsMapWithTheirIDsHeightsAndTrees() throws {
        let chain = LayoutNode.split(id: 41, direction: .down, ratio: 0.6, a: .leaf(4),
                                     b: .split(id: 7, direction: .right, ratio: 0.5, a: .leaf(5), b: .leaf(6)))
        let snapshot = ColumnSnapshot(id: 14, width: 1, layout: chain, rows: [
            RowSnapshot(id: 40, height: 600, layout: .leaf(4)),
            RowSnapshot(id: 41, height: 400, layout: .split(id: 7, direction: .right, ratio: 0.5, a: .leaf(5), b: .leaf(6))),
        ])
        let (mapped, handles) = map(snapshot)
        let column = try #require(mapped)
        #expect(column.rows.map(\.id) == [LayoutRowID("row:40"), LayoutRowID("row:41")])
        #expect(column.rows.map(\.height) == [600, 400])
        #expect(column.rows[0].root == .leaf("p4"))
        #expect(column.rows[1].root.panes == ["p5", "p6"])
        #expect(handles.rows[LayoutRowID("row:41")] == DaemonRowID(rawValue: 41))
        #expect(handles.splits[LayoutSplitID("split:7")] == DaemonSplitID(rawValue: 7))
        // The single tree stays the compat chain, so every pane query holds.
        #expect(column.root.panes == ["p4", "p5", "p6"])
    }

    @Test func aColumnWithoutRowsKeepsItsTree() throws {
        let (mapped, handles) = map(ColumnSnapshot(id: 9, width: 0.5, layout: .leaf(4)))
        let column = try #require(mapped)
        #expect(column.rows.isEmpty)
        #expect(column.root == .leaf("p4"))
        #expect(handles.rows.isEmpty)
    }

    /// A row whose panes this client cannot show drops out; heights stay
    /// as the daemon stored them (the fill rule absorbs the gap).
    @Test func anEmptyRowDropsOut() throws {
        let snapshot = ColumnSnapshot(id: 14, width: 1, layout: .split(id: 41, direction: .down, ratio: 0.5, a: .leaf(4), b: .leaf(99)),
                                      rows: [RowSnapshot(id: 40, height: 500, layout: .leaf(4)),
                                             RowSnapshot(id: 41, height: 500, layout: .leaf(99))])
        let column = try #require(map(snapshot).0)
        #expect(column.rows.isEmpty, "one row left is a column without rows")
        #expect(column.root == .leaf("p4"))
    }

    @Test func heightsClampToTheDaemonRange() throws {
        let snapshot = ColumnSnapshot(id: 14, width: 1, layout: .split(id: 41, direction: .down, ratio: 0.5, a: .leaf(4), b: .leaf(5)),
                                      rows: [RowSnapshot(id: 40, height: 20, layout: .leaf(4)),
                                             RowSnapshot(id: 41, height: 4000, layout: .leaf(5))])
        let column = try #require(map(snapshot).0)
        #expect(column.rows.map(\.height) == [100, 1000])
    }
}
