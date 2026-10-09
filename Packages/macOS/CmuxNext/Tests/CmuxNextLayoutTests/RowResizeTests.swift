import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// The rows of a column as a vertical strip behind the `RowScroll`
/// adapter: the column scroll rules reveal the focused row (rows.md V1)
/// and stay put otherwise; strip slots never carry row ids.
struct RowStripTests {
    private let rows = [LayoutRow(id: "r1", height: 1000, root: .leaf("a")), LayoutRow(id: "r2", height: 500, root: .leaf("b"))]

    private func strip(_ scroll: inout RowScroll, rows: [LayoutRow]? = nil) -> ColumnStrip {
        let rows = rows ?? self.rows
        let column = LayoutColumn(id: "c", width: 1, root: .leaf("a"), rows: rows)
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: CGRect(x: 20, y: 10, width: 400, height: 600), gap: 8, scale: 1)
        var panes: [PaneID: CGRect] = [:]
        for (row, placed) in zip(rows, stack.rows) { for pane in row.root.panes { panes[pane] = placed.frame } }
        return scroll.strip(rows: stack, column: column, panes: panes)
    }

    @Test func rowsBecomeAStripMeasuredFromTheColumnTop() {
        var scroll = RowScroll()
        let strip = strip(&scroll)
        #expect(strip.viewportWidth == 600)
        #expect(strip.contentWidth == 904)
        #expect(strip.columns.map(\.frame.minX) == [0, 608])
        #expect(strip.columns[1].frame.width == 296)
        #expect(strip.index(ofPane: "b") == 1)
        #expect(strip.columns.allSatisfy { !$0.id.rawValue.contains("r1") && !$0.id.rawValue.contains("r2") })
        #expect(scroll.row(forSlot: strip.columns[1].id) == "r2")
    }

    @Test func slotsStayStableWhileARowLivesAndDieWithIt() {
        var scroll = RowScroll()
        let first = strip(&scroll)
        let inserted = [rows[0], LayoutRow(id: "r9", height: 300, root: .leaf("z")), rows[1]]
        let second = strip(&scroll, rows: inserted)
        #expect(second.columns[0].id == first.columns[0].id)
        #expect(second.columns[2].id == first.columns[1].id)
        _ = strip(&scroll, rows: [rows[0], rows[1]])
        #expect(scroll.row(forSlot: second.columns[1].id) == nil)
    }

    @Test func focusingAHiddenRowRevealsItAndBackKeepsTheCamera() {
        var scroll = RowScroll()
        var current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: "a", source: .programmatic, animated: false))
        #expect(scroll.state.spring.value == 0)
        current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: "b", source: .keyboard, animated: false))
        #expect(scroll.state.spring.value == 304, "the bottom row aligns with the column's bottom edge")
        current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: nil, source: .keyboard, animated: false))
        #expect(scroll.state.spring.value == 304, "focus elsewhere does not move the rows")
    }
}
