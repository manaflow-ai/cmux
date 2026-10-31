import CoreGraphics

/// R3b of the resize audit (Lawrence 2026-10-31, binding: "creating new columns must never resize
/// existing columns"): a create that adds a column, New Column or Split Right (cmux-ad 2026-10-31: both
/// add one; Split Down does not), leaves every pane that existed before at its width in points, exactly;
/// the new column takes new space.
///
/// A screen records its panes' rest widths, which its geometry already holds, before the first such
/// change since its last check (``noteChange(from:to:viewportWidth:)``); the check compares them once
/// the layout settled (``take(_:viewportWidth:)``), so a create that resizes in two steps (the new
/// column, then a width command) is caught too. A change of the screen's own width in between drops
/// the record (column widths are fractions of it), and so does a person's drag.
nonisolated struct ColumnWidthLedger: Sendable, Equatable {
    /// A screen at rest: its panes' widths and the column of each, and what a create adds to.
    struct Shape: Sendable, Equatable {
        var widths: [PaneID: CGFloat] = [:]
        /// Each pane's column id, "screen" for a screen stored as one split tree (for the log).
        var columnOf: [PaneID: String] = [:]
        /// The stored columns; empty for a split tree.
        var columns: Set<ColumnID> = []
        /// Splits whose children are side by side: a Split Right adds one.
        var sideBySide: Set<SplitID> = []
    }

    /// A pane a create resized: its id, its column, its width before and after.
    struct Change: Sendable, Equatable, CustomStringConvertible {
        var pane: PaneID
        var column: String
        var before: CGFloat
        var after: CGFloat
        var description: String { "pane \(pane.rawValue) (column \(column)) \(before)->\(after)" }
    }

    /// Float noise below this is not a width change (frames are rounded to device pixels).
    static let tolerance: CGFloat = 0.001

    /// The screen's width and its panes' widths before the first create since the last check.
    private(set) var record: Record?

    struct Record: Sendable, Equatable {
        var viewportWidth: CGFloat
        var widths: [PaneID: CGFloat]
    }

    /// `layout` at its rest frames in `geometry`.
    static func shape(of layout: ScreenLayout, in geometry: ScreenGeometry) -> Shape {
        var shape = Shape()
        let trees: [(column: String, root: SplitNode)] = switch layout {
        case .splits(let root): [("screen", root)]
        case .columns(let columns): columns.map { ($0.id.rawValue, $0.root) }
        }
        if case .columns(let columns) = layout { shape.columns = Set(columns.map(\.id)) }
        for tree in trees {
            for pane in tree.root.panes {
                shape.columnOf[pane] = tree.column
                if let frame = geometry.panes[pane] { shape.widths[pane] = frame.width }
            }
            shape.sideBySide.formUnion(tree.root.splits.filter { tree.root.node(for: $0)?.axis == .horizontal })
        }
        return shape
    }

    /// Whether going from `before` to `after` creates a column: a new pane, with a new column (a second
    /// column of what was one split tree) or a new side-by-side split. A pane added below another (Split
    /// Down, a new row) or a change that adds no pane (a move, a width preset) is not one.
    static func addsColumn(from before: Shape, to after: Shape) -> Bool {
        guard after.widths.keys.contains(where: { before.widths[$0] == nil }) else { return false }
        let newColumn = before.columns.isEmpty ? after.columns.count > 1 : !after.columns.isSubset(of: before.columns)
        return newColumn || !after.sideBySide.isSubset(of: before.sideBySide)
    }

    /// The screen's layout changed from `before` to `after` while it was `viewportWidth` points wide.
    mutating func noteChange(from before: Shape, to after: Shape, viewportWidth: CGFloat) {
        guard viewportWidth > 0, Self.addsColumn(from: before, to: after) else { return }
        guard var record, record.viewportWidth == viewportWidth else {
            record = Record(viewportWidth: viewportWidth, widths: before.widths)
            return
        }
        // A second create before the check: the panes the first one made keep their widths too.
        record.widths.merge(before.widths) { first, _ in first }
        self.record = record
    }

    /// Forgets the record (a person's drag sets widths on purpose).
    mutating func drop() {
        record = nil
    }

    /// The recorded panes whose width differs in `current`, and clears the record. A pane that is gone
    /// is not compared.
    mutating func take(_ current: Shape, viewportWidth: CGFloat) -> [Change] {
        // Red stub (R3b): compares nothing yet.
        record = nil
        return []
    }
}
