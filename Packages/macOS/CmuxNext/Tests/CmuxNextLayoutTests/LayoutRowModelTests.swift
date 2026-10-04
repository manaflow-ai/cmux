import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// `LayoutColumn.rows` (plans/cmux-next/rows.md): the single tree stays the
/// compat chain; ratio changes reach the row trees too.
struct LayoutRowModelTests {
    static let inner = SplitNode.split("s7", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))
    static let column = LayoutColumn(
        id: "col", width: 1,
        root: .split("r2", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: inner),
        rows: [LayoutRow(id: "r1", height: 500, root: .leaf("a")), LayoutRow(id: "r2", height: 500, root: inner)]
    )

    @Test func rowQueries() {
        #expect(Self.column.hasRows)
        #expect(Self.column.row(containing: "c")?.id == "r2")
        #expect(Self.column.row(containing: "zz") == nil)
        #expect(LayoutColumn(id: "x", root: .leaf("a")).hasRows == false)
    }

    @Test func settingARatioReachesTheRowTree() {
        let layout = ScreenLayout.columns([Self.column]).settingRatio(0.3, for: "s7")
        let column = layout.columns[0]
        #expect(column.rows[1].root.ratio(of: "s7") == 0.3)
        #expect(column.root.ratio(of: "s7") == 0.3)
    }

    @Test func rowChangesAreStructural() {
        let base = ScreenLayout.columns([Self.column])
        var regrown = Self.column
        regrown.rows[0].height = 300
        regrown.rows[1].height = 700
        #expect(base.hasSameStructure(as: .columns([regrown])), "heights are sizes, not structure")
        var moved = Self.column
        moved.rows = [LayoutRow(id: "r1", height: 500, root: .leaf("a")), LayoutRow(id: "r3", height: 500, root: Self.inner)]
        #expect(!base.hasSameStructure(as: .columns([moved])))
    }
}
