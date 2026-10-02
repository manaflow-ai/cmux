/// One scrollable column. Its width is a fraction of the viewport.
public nonisolated struct LayoutColumn: Hashable, Sendable, Identifiable {
    public var id: ColumnID
    /// Fraction of the viewport width, 0.1...1.0 (daemon `set-viewport-pane-width`).
    public var width: Double
    public var root: SplitNode
    /// Pinned to a viewport edge (daemon `columns[].sticky`); nil scrolls.
    public var sticky: StickyColumn?

    public init(id: ColumnID, width: Double = ColumnWidthPreset.defaultWidth, root: SplitNode, sticky: StickyColumn? = nil) {
        self.id = id
        self.width = width
        self.root = root
        self.sticky = sticky
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

    /// Columns in the order the user sees them: the left sticky column, the
    /// scrolling strip, the right sticky column (StickyStripGeometry S1, S2).
    public var visualColumns: [LayoutColumn] {
        let parts = StickyStripGeometry.partition(columns)
        return [parts.left].compactMap { $0 } + parts.scrolling + [parts.right].compactMap { $0 }
    }

    /// The column that contains `pane`, in columns mode.
    public func column(containing pane: PaneID) -> LayoutColumn? {
        columns.first { $0.root.contains(pane) }
    }

    /// The split tree that contains `split`.
    public func tree(containing split: SplitID) -> SplitNode? {
        switch self {
        case let .splits(root): root.node(for: split) == nil ? nil : root
        case let .columns(columns): columns.first { $0.root.node(for: split) != nil }?.root
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
            return .columns(columns.map { column in
                var column = column
                column.root = column.root.settingRatio(ratio, for: split)
                return column
            })
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
                $0.id == $1.id && $0.sticky == $1.sticky && $0.root.hasSameShape(as: $1.root)
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

    /// A copy with `column` made sticky (or scrolling for nil), keeping the
    /// daemon's rules: another column on the same edge scrolls again.
    public func settingSticky(_ sticky: StickyColumn?, for column: ColumnID) -> ScreenLayout {
        guard case let .columns(columns) = self else { return self }
        return .columns(columns.map { entry in
            var entry = entry
            if entry.id == column {
                entry.sticky = sticky
            } else if let sticky, entry.sticky?.edge == sticky.edge {
                entry.sticky = nil
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
}
