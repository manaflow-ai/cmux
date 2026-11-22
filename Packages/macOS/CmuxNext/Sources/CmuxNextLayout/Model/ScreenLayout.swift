/// One scrollable column. Its width is a fraction of the viewport.
public nonisolated struct LayoutColumn: Hashable, Sendable, Identifiable {
    public var id: ColumnID
    /// Fraction of the viewport width, 0.1...1.0 (daemon `set-viewport-pane-width`).
    public var width: Double
    /// Every pane of the column. With `rows`, the daemon's compat chain
    /// (rows folded into vertical splits), which pane and split queries
    /// read; geometry lays out `rows` instead.
    public var root: SplitNode
    /// Pinned to a viewport edge (daemon `columns[].dock`); nil scrolls.
    public var dock: DockColumn?
    /// The column's rows, top to bottom (`rows-v1`, plans/cmux-next/rows.md);
    /// empty for a column with one row, which is today's column.
    public var rows: [LayoutRow]

    public init(id: ColumnID, width: Double = ColumnWidthPreset.defaultWidth, root: SplitNode, dock: DockColumn? = nil,
                rows: [LayoutRow] = []) {
        self.id = id
        self.width = width
        self.root = root
        self.dock = dock
        self.rows = rows
    }

    /// Two or more rows (a single row is the column's own tree).
    public var hasRows: Bool { rows.count > 1 }

    /// The row holding `pane`.
    public func row(containing pane: PaneID) -> LayoutRow? {
        rows.first { $0.root.contains(pane) }
    }

    /// The split trees the user sees: each row's, or the column's own. A
    /// row split of the compat chain is in none of them (the daemon refuses
    /// it, `row-split-compat-readonly`).
    public var trees: [SplitNode] { hasRows ? rows.map(\.root) : [root] }

    /// The tree holding `pane`: its row's, or the column's own.
    public func tree(containing pane: PaneID) -> SplitNode? {
        trees.first { $0.contains(pane) }
    }

    /// A copy with `split`'s ratio replaced in the tree and in every row.
    func settingRatio(_ ratio: Double, for split: SplitID) -> LayoutColumn {
        var column = self
        column.root = root.settingRatio(ratio, for: split)
        for index in column.rows.indices {
            column.rows[index].root = column.rows[index].root.settingRatio(ratio, for: split)
        }
        return column
    }

    /// Same rows with the same tree shapes; heights may differ.
    func hasSameRows(as other: LayoutColumn) -> Bool {
        rows.count == other.rows.count && zip(rows, other.rows).allSatisfy { $0.id == $1.id && $0.root.hasSameShape(as: $1.root) }
    }
}

/// The content of one screen.
public nonisolated enum ScreenLayout: Hashable, Sendable {
    /// A normal tiled split tree filling the viewport.
    case splits(SplitNode)
    /// Horizontally scrollable columns, each owning a split tree.
    case columns([LayoutColumn])

    public var panes: [PaneID] {
        switch self {
        case let .splits(root): root.panes
        case let .columns(columns): columns.flatMap(\.root.panes)
        }
    }

    public func contains(_ pane: PaneID) -> Bool {
        switch self {
        case let .splits(root): root.contains(pane)
        case let .columns(columns): columns.contains { $0.root.contains(pane) }
        }
    }

    public var columns: [LayoutColumn] {
        if case let .columns(columns) = self { return columns }
        return []
    }

    /// Columns in the order the user sees them: the left dock, the top dock,
    /// the scrolling strip, the bottom dock, the right dock
    /// (DockStripGeometry S1, S2; layout-model.md). Focus, close-focus and
    /// column navigation read this, so every dock stays reachable.
    public var visualColumns: [LayoutColumn] {
        let parts = DockStripGeometry.docks(columns)
        return [parts.left, parts.top].compactMap { $0 } + parts.scrolling + [parts.bottom, parts.right].compactMap { $0 }
    }

    /// The column that contains `pane`, in columns mode.
    public func column(containing pane: PaneID) -> LayoutColumn? {
        columns.first { $0.root.contains(pane) }
    }

    /// The split tree that contains `split`.
    public func tree(containing split: SplitID) -> SplitNode? {
        switch self {
        case let .splits(root): root.node(for: split) == nil ? nil : root
        case let .columns(columns): columns.lazy.compactMap { $0.trees.first { $0.node(for: split) != nil } }.first
        }
    }

    public func ratio(of split: SplitID) -> Double? {
        switch self {
        case let .splits(root): root.ratio(of: split)
        case let .columns(columns): columns.lazy.compactMap { $0.root.ratio(of: split) }.first
        }
    }

    public func settingRatio(_ ratio: Double, for split: SplitID) -> ScreenLayout {
        switch self {
        case let .splits(root):
            return .splits(root.settingRatio(ratio, for: split))
        case let .columns(columns):
            return .columns(columns.map { $0.settingRatio(ratio, for: split) })
        }
    }

    /// Same panes, splits and columns in the same places; ratios and widths
    /// may differ. A change that fails this (split, close, move, new column)
    /// is structural and applies without animation.
    public func hasSameStructure(as other: ScreenLayout) -> Bool {
        switch (self, other) {
        case let (.splits(x), .splits(y)):
            return x.hasSameShape(as: y)
        case let (.columns(x), .columns(y)):
            return x.count == y.count && zip(x, y).allSatisfy {
                $0.id == $1.id && $0.dock == $1.dock && $0.root.hasSameShape(as: $1.root) && $0.hasSameRows(as: $1)
            }
        default:
            return false
        }
    }

    public func settingWidth(_ width: Double, for column: ColumnID) -> ScreenLayout {
        guard case let .columns(columns) = self else { return self }
        return .columns(columns.map { entry in
            guard entry.id == column else { return entry }
            var entry = entry
            entry.width = width
            return entry
        })
    }

    /// A copy with the named rows of `column` at new heights (a row divider
    /// drag's local preview; never model state).
    public func settingRowHeights(_ heights: [RowHeight], for column: ColumnID) -> ScreenLayout {
        guard case let .columns(columns) = self else { return self }
        let byRow = Dictionary(heights.map { ($0.row, $0.height) }, uniquingKeysWith: { _, new in new })
        return .columns(columns.map { entry in
            guard entry.id == column else { return entry }
            var entry = entry
            for index in entry.rows.indices { entry.rows[index].height = byRow[entry.rows[index].id] ?? entry.rows[index].height }
            return entry
        })
    }

    /// A copy with `column` made docked (or scrolling for nil), keeping the
    /// daemon's rules: another column on the same edge scrolls again.
    public func settingDock(_ dock: DockColumn?, for column: ColumnID) -> ScreenLayout {
        guard case let .columns(columns) = self else { return self }
        return .columns(columns.map { entry in
            var entry = entry
            if entry.id == column {
                entry.dock = dock
            } else if let dock, entry.dock?.edge == dock.edge {
                entry.dock = nil
            }
            return entry
        })
    }
}

/// One screen of a workspace.
public nonisolated struct LayoutScreen: Hashable, Sendable, Identifiable {
    public var id: ScreenID
    public var name: String
    public var layout: ScreenLayout

    public init(id: ScreenID, name: String, layout: ScreenLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }

    /// Every screen is a column strip: a screen stored as one split tree is
    /// one implicit column holding that tree, with this id.
    public var implicitColumnID: ColumnID { ColumnID("implicit:\(id.rawValue)") }

    /// The column holding `pane`: a stored column, or the implicit column of
    /// a screen stored as one split tree.
    public func column(containing pane: PaneID) -> LayoutColumn? {
        switch layout {
        case let .splits(root): root.contains(pane) ? LayoutColumn(id: implicitColumnID, width: 1, root: root) : nil
        case .columns: layout.column(containing: pane)
        }
    }

    /// The column with `id`, including the implicit one.
    public func column(id: ColumnID) -> LayoutColumn? {
        switch layout {
        case let .splits(root): id == implicitColumnID ? LayoutColumn(id: id, width: 1, root: root) : nil
        case let .columns(columns): columns.first { $0.id == id }
        }
    }
}
