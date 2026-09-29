/// Orientation of a split.
public nonisolated enum SplitAxis: String, Hashable, Sendable {
    /// Children side by side; `a` is on the left. Daemon `dir: "right"`.
    case horizontal
    /// Children stacked; `a` is on top. Daemon `dir: "down"`.
    case vertical
}

/// A binary split tree whose leaves are panes.
public nonisolated indirect enum SplitNode: Hashable, Sendable {
    case leaf(PaneID)
    /// `ratio` is the fraction of the space (minus the divider) given to `a`.
    case split(SplitID, axis: SplitAxis, ratio: Double, a: SplitNode, b: SplitNode)

    /// Leaves in visual order (left to right, top to bottom).
    public var panes: [PaneID] {
        var result: [PaneID] = []
        collectPanes(into: &result)
        return result
    }

    private func collectPanes(into result: inout [PaneID]) {
        switch self {
        case let .leaf(pane): result.append(pane)
        case let .split(_, _, _, a, b):
            a.collectPanes(into: &result)
            b.collectPanes(into: &result)
        }
    }

    /// Every split id in the tree, depth first.
    public var splits: [SplitID] {
        switch self {
        case .leaf: []
        case let .split(id, _, _, a, b): [id] + a.splits + b.splits
        }
    }

    public func contains(_ pane: PaneID) -> Bool {
        switch self {
        case let .leaf(leaf): leaf == pane
        case let .split(_, _, _, a, b): a.contains(pane) || b.contains(pane)
        }
    }

    /// The ratio of `split`, if it exists in this tree.
    public func ratio(of split: SplitID) -> Double? {
        switch self {
        case .leaf: return nil
        case let .split(id, _, ratio, a, b):
            if id == split { return ratio }
            return a.ratio(of: split) ?? b.ratio(of: split)
        }
    }

    /// Axis and children of `split`, if it exists in this tree.
    public func node(for split: SplitID) -> (axis: SplitAxis, a: SplitNode, b: SplitNode)? {
        switch self {
        case .leaf: return nil
        case let .split(id, axis, _, a, b):
            if id == split { return (axis, a, b) }
            return a.node(for: split) ?? b.node(for: split)
        }
    }

    /// A copy with `split`'s ratio replaced. Unchanged if the split is absent.
    public func settingRatio(_ ratio: Double, for split: SplitID) -> SplitNode {
        switch self {
        case .leaf: return self
        case let .split(id, axis, old, a, b):
            if id == split { return .split(id, axis: axis, ratio: ratio, a: a, b: b) }
            return .split(id, axis: axis, ratio: old, a: a.settingRatio(ratio, for: split), b: b.settingRatio(ratio, for: split))
        }
    }

    /// Number of equal cells this subtree contributes along `axis`. A chain of
    /// same-axis splits counts its leaves; a perpendicular subtree counts as one.
    public func cellCount(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf: return 1
        case let .split(_, nodeAxis, _, a, b):
            return nodeAxis == axis ? a.cellCount(along: axis) + b.cellCount(along: axis) : 1
        }
    }

    /// The ratio for `split` that gives every cell in its same-axis chain equal size.
    public func equalizedRatio(for split: SplitID) -> Double? {
        guard let node = node(for: split) else { return nil }
        let a = Double(node.a.cellCount(along: node.axis))
        let b = Double(node.b.cellCount(along: node.axis))
        return a / (a + b)
    }
}

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

/// niri-style column width presets (`switch-preset-column-width`).
public nonisolated enum ColumnWidthPreset: Double, CaseIterable, Sendable {
    case oneThird = 0.3333333333333333
    case half = 0.5
    case twoThirds = 0.6666666666666666
    case full = 1.0

    /// Width of a new column: two-thirds of the viewport (daemon default 0.667).
    public static let defaultWidth: Double = 2.0 / 3.0

    /// Daemon-accepted width range.
    public static let widthRange: ClosedRange<Double> = 0.1...1.0

    /// The next preset strictly wider (forward) or narrower (backward) than
    /// `width`, wrapping around like niri.
    public static func next(after width: Double, forward: Bool = true) -> ColumnWidthPreset {
        let epsilon = 0.01
        let all = allCases
        if forward {
            return all.first { $0.rawValue > width + epsilon } ?? all[0]
        }
        return all.last { $0.rawValue < width - epsilon } ?? all[all.count - 1]
    }
}

/// Daemon-accepted split ratio range.
public nonisolated enum SplitRatio {
    public static let range: ClosedRange<Double> = 0.05...0.95
}
