import CoreGraphics

/// R3b of the resize audit (Lawrence's rule, scope by cmux-ad 2026-10-31): a create keeps every other
/// column's width in points, exactly. New Column (the action, Ctrl-Cmd-D) keeps every old column as it was
/// and the new column takes new space; Cmd-D and Split Down split inside a column, whose own panes share it,
/// and no other column changes width.
///
/// A screen records its columns' rest widths, which its geometry already holds, before the first create
/// (a change that adds a pane) since its last check (``noteChange(from:to:viewportWidth:)``); the check
/// compares them once the layout settled (``take(_:viewportWidth:)``), so a create that resizes in two steps
/// (the new pane, then a width command) is caught too. The column that took a new pane by a split is not
/// compared. A change of the screen's own width in between drops the record (column widths are fractions
/// of it), and so does a person's drag.
nonisolated struct ColumnWidthLedger: Sendable, Equatable {
    /// One column at rest: its id (nil for a screen stored as one split tree), its panes, its width.
    struct Column: Sendable, Equatable {
        var id: ColumnID?
        var panes: Set<PaneID>
        var width: CGFloat
        /// Pinned to a viewport edge: a dock that comes or goes moves the strip's edges, which is not a create.
        var docked = false
    }

    /// A column a create resized: its id ("screen" for a split tree's), its width before and after.
    struct Change: Sendable, Equatable, CustomStringConvertible {
        var column: String
        var before: CGFloat
        var after: CGFloat
        var description: String { "column \(column) \(before)->\(after)" }
    }

    /// Float noise below this is not a width change (frames are rounded to device pixels).
    static let tolerance: CGFloat = 0.001

    /// The screen's width and its columns before the first create since the last check.
    private(set) var record: Record?

    struct Record: Sendable, Equatable {
        var viewportWidth: CGFloat
        var columns: [Column]
    }

    /// `layout`'s columns at their rest widths in `geometry`. A split tree is the screen's implicit column of
    /// width 1 (``LayoutScreen/implicitColumnID``): as wide as a lone full-width column of the strip.
    static func columns(of layout: ScreenLayout, in geometry: ScreenGeometry, gap: CGFloat, scale: CGFloat) -> [Column] {
        switch layout {
        case .splits(let root):
            let width = ColumnStripGeometry.frames(widths: [1], viewport: geometry.viewport, gap: gap, scale: scale).frames.first?.width
            return [Column(id: nil, panes: Set(root.panes), width: width ?? geometry.viewport.width)]
        case .columns(let columns):
            return columns.compactMap { column in
                geometry.columns[column.id].map { Column(id: column.id, panes: Set(column.root.panes), width: $0.width, docked: column.dock != nil) }
            }
        }
    }

    /// The screen's layout changed from `before` to `after` while it was `viewportWidth` points wide: a
    /// create (a pane `before` did not have) is recorded; a move, a close, a width change or a change of
    /// the docks (out of R3b's scope: New Column, Cmd-D, Split Down) is not.
    mutating func noteChange(from before: [Column], to after: [Column], viewportWidth: CGFloat) {
        let panes = before.reduce(into: Set<PaneID>()) { $0.formUnion($1.panes) }
        func docks(_ columns: [Column]) -> Set<ColumnID?> { Set(columns.filter(\.docked).map(\.id)) }
        guard viewportWidth > 0, docks(before) == docks(after),
              after.contains(where: { !$0.panes.isSubset(of: panes) }) else { return }
        guard var record, record.viewportWidth == viewportWidth else {
            record = Record(viewportWidth: viewportWidth, columns: before)
            return
        }
        // A second create before the check: the columns the first one made keep their widths too.
        let known = Set(record.columns.compactMap(\.id))
        record.columns += before.filter { $0.id.map { !known.contains($0) } ?? false }
        self.record = record
    }

    /// Forgets the record (a person's drag sets widths on purpose).
    mutating func drop() {
        record = nil
    }

    /// The recorded columns whose width differs in `current`, and clears the record. A column that is gone
    /// is not compared, nor one that took a new pane (a split inside it); a split tree's column is the
    /// column that holds most of its panes now.
    mutating func take(_ current: [Column], viewportWidth: CGFloat) -> [Change] {
        guard let record else { return [] }
        self.record = nil
        guard record.viewportWidth == viewportWidth else { return [] }
        let recorded = record.columns.reduce(into: Set<PaneID>()) { $0.formUnion($1.panes) }
        return record.columns.compactMap { old in
            let now: Column? = if let id = old.id {
                current.first { $0.id == id }
            } else {
                current.filter { !$0.panes.isDisjoint(with: old.panes) }
                    .max { $0.panes.intersection(old.panes).count < $1.panes.intersection(old.panes).count }
            }
            guard let now, now.panes.isSubset(of: recorded), abs(now.width - old.width) > Self.tolerance else { return nil }
            return Change(column: old.id?.rawValue ?? "screen", before: old.width, after: now.width)
        }
    }
}
