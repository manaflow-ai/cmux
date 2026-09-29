/// One niri-style scrollable column. Its width is a fraction of the viewport.
public nonisolated struct LayoutColumn: Hashable, Sendable, Identifiable {
    public var id: ColumnID
    /// Fraction of the viewport width, 0.1...1.0 (daemon `set-viewport-pane-width`).
    public var width: Double
    public var root: SplitNode

    public init(id: ColumnID, width: Double = ColumnWidthPreset.defaultWidth, root: SplitNode) {
        self.id = id
        self.width = width
        self.root = root
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

    public func settingWidth(_ width: Double, for column: ColumnID) -> ScreenLayout {
        guard case let .columns(columns) = self else { return self }
        return .columns(columns.map { $0.id == column ? LayoutColumn(id: $0.id, width: width, root: $0.root) : $0 })
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
