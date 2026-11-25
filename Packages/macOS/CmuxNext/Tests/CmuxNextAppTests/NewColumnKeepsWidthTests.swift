import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// R3b (Lawrence 2026-10-31): "creating new columns must never resize existing columns". After any
/// create that makes a column, every column that was there keeps its width exactly, in points; the
/// new column is new space and the strip scrolls. The daemon stores each column's width; the app
/// plans only the new column's width and sends no other width, and lays a
/// split-tree screen out as the full-width column it becomes.
@MainActor
struct NewColumnKeepsWidthTests {
    nonisolated static let modes: [NewColumnWidthMode] = [.fixed, .matchCurrent, .fitScreen]

    /// The screen shapes a column opens on: a lone full-width column (a workspace that never had a
    /// second column, and a zoomed screen, both mirrored as one full-width column), columns of
    /// uneven widths beside the focused one, and two visible halves.
    static let shapes: [(name: String, columns: [LayoutColumn], anchor: ColumnID, visible: [ColumnID])] = [
        ("lone full-width column", [LayoutColumn(id: "c0", width: 1, root: .leaf("p0"))], "c0", ["c0"]),
        ("uneven columns", [LayoutColumn(id: "c0", width: 0.45, root: .leaf("p0")),
                            LayoutColumn(id: "c1", width: 0.8, root: .leaf("p1")),
                            LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2"))], "c1", ["c0", "c1"]),
        ("two visible halves", [LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")),
                                LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))], "c1", ["c0", "c1"]),
    ]

    /// In every `layout.newColumnWidth` mode, on every shape, the plan is the new column's width and
    /// nothing else: no existing column resizes.
    @Test(arguments: modes)
    func aNewColumnPlansNoResize(mode: NewColumnWidthMode) {
        for shape in Self.shapes {
            let plan = NewColumnWidth.plan(mode: mode, columns: shape.columns, anchor: shape.anchor, visible: shape.visible,
                                           fixedWidth: 2.0 / 3.0)
            #expect(plan == NewColumnPlan(width: plan.width), "\(mode), \(shape.name): \(plan)")
            // A tab dragged out of its pane into the new column (the pane closes with it): same rule.
            let dragged = NewColumnWidth.plan(mode: mode, columns: shape.columns, anchor: shape.anchor, visible: shape.visible,
                                              fixedWidth: 2.0 / 3.0, removing: "p2")
            #expect(dragged == NewColumnPlan(width: dragged.width), "\(mode), \(shape.name), dragged: \(dragged)")
        }
    }

    /// The first column beside a split-tree screen: the tree's panes keep their frames in points
    /// once the tree is the full-width column beside the new one (no strip gap, the default
    /// edge-to-edge separation; with a gap a column is inset by it, a separate design question).
    @Test func theFirstColumnKeepsTheTreesPanesWhereTheyWere() {
        let gap: CGFloat = 0
        var style = LayoutStyle()
        style.columnGap = gap
        style.panePadding = 0
        let tree = SplitNode.split("s1", axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1"))
        let viewport = CGSize(width: 1200, height: 800)
        let before = ScreenGeometry.compute(.splits(tree), viewport: viewport, style: style, scale: 2)
        let after = ScreenGeometry.compute(.columns([LayoutColumn(id: "tree", width: 1, root: tree),
                                                     LayoutColumn(id: "new", width: 2.0 / 3.0, root: .leaf("p2"))]),
                                           viewport: viewport, style: style, scale: 2)
        for pane: PaneID in ["p0", "p1"] {
            #expect(before.panes[pane] == after.panes[pane],
                    "gap \(gap): \(pane) was \(String(describing: before.panes[pane])), now \(String(describing: after.panes[pane]))")
        }
    }

    /// Columns that existed keep their frames in points when a column opens between them or at either
    /// end at the planned width: only later columns move along, and the strip grows.
    @Test(arguments: modes)
    func existingColumnsKeepTheirPointWidths(mode: NewColumnWidthMode) {
        let style = LayoutStyle()
        let viewport = CGSize(width: 1200, height: 800)
        for shape in Self.shapes {
            let plan = NewColumnWidth.plan(mode: mode, columns: shape.columns, anchor: shape.anchor, visible: shape.visible,
                                           fixedWidth: 2.0 / 3.0)
            let before = ScreenGeometry.compute(.columns(shape.columns), viewport: viewport, style: style, scale: 2)
            for index in 0...shape.columns.count {
                var columns = shape.columns
                columns.insert(LayoutColumn(id: "new", width: plan.width, root: .leaf("pn")), at: index)
                let after = ScreenGeometry.compute(.columns(columns), viewport: viewport, style: style, scale: 2)
                for column in shape.columns {
                    #expect(before.columns[column.id]?.width == after.columns[column.id]?.width,
                            "\(mode), \(shape.name), new column at \(index): \(column.id) was \(String(describing: before.columns[column.id]?.width)), now \(String(describing: after.columns[column.id]?.width))")
                }
                #expect(after.contentWidth > before.contentWidth - 0.5, "\(mode), \(shape.name): the strip shrank")
            }
        }
    }
}
