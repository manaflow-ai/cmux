public import CoreGraphics

/// Option-dragging a split divider in a scrolling column (resize-modifiers.md): the column grows or
/// shrinks by the pointer's travel and the columns after it move along (the strip scrolls), so the
/// panes before the divider's leading side and after it keep their widths. Only the pane on the
/// divider's leading side changes, like dragging the trailing edge of that one pane.
///
/// Built from the drag's start; ``targets(delta:)`` is pure, so every frame derives from the start
/// and nothing drifts.
public nonisolated struct PushResize: Hashable, Sendable {
    /// A horizontal split on the path from the column's tree root to the dragged divider, with its
    /// leading child's extent and its room at the start.
    public struct Ancestor: Hashable, Sendable {
        public var split: SplitID
        public var leading: CGFloat
        public var available: CGFloat
        /// The dragged divider is this split, or lies in its leading child: the leading child grows.
        public var growsLeading: Bool
    }

    public var column: ColumnID
    /// The column's width in points at the start.
    public var columnWidth: CGFloat
    /// Ancestors, the dragged split last.
    public var ancestors: [Ancestor]
    /// How far the divider may move left: its leading child keeps its minimum.
    public var minimumDelta: CGFloat
    /// How far it may move right: the column stays within the widest share.
    public var maximumDelta: CGFloat
    public var viewport: CGFloat
    public var gap: CGFloat

    /// Plans a push for `split` in `column`, or nil when the divider does not split across the
    /// strip (a vertical divider) or the column is docked.
    public init?(split: SplitID, column: LayoutColumn, columnWidth: CGFloat, dividers: [DividerGeometry], viewport: CGFloat,
                 gap: CGFloat, dividerThickness: CGFloat) {
        guard column.dock == nil, let tree = column.trees.first(where: { $0.node(for: split) != nil }),
              let path = tree.horizontalPath(to: split), !path.isEmpty else { return nil }
        let frames = Dictionary(dividers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ancestors: [Ancestor] = []
        for step in path {
            guard let divider = frames[step.split] else { return nil }
            ancestors.append(Ancestor(split: step.split, leading: divider.frame.minX - divider.container.minX,
                                      available: max(1, divider.container.width - dividerThickness), growsLeading: step.growsLeading))
        }
        guard let dragged = frames[split] else { return nil }
        self.column = column.id
        self.columnWidth = columnWidth
        self.ancestors = ancestors
        let narrowest = ColumnStripGeometry.pixelWidth(fraction: ColumnWidthPreset.widthRange.lowerBound, viewportWidth: viewport, gap: gap)
        let widest = ColumnStripGeometry.pixelWidth(fraction: ColumnWidthPreset.widthRange.upperBound, viewportWidth: viewport, gap: gap)
        minimumDelta = min(0, max(dragged.minimumA - (dragged.frame.minX - dragged.container.minX), narrowest - columnWidth))
        maximumDelta = max(0, widest - columnWidth)
        self.viewport = viewport
        self.gap = gap
    }

    /// The column's width and every ancestor's ratio with the divider `delta` points from its start.
    public func targets(delta: CGFloat) -> [DividerDragValue] {
        let delta = min(max(delta, minimumDelta), maximumDelta)
        let width = ColumnStripGeometry.fraction(forPixelWidth: columnWidth + delta, viewportWidth: viewport, gap: gap)
        return [.width(column, width)] + ancestors.map { step in
            let leading = step.leading + (step.growsLeading ? delta : 0)
            let ratio = Double(leading / (step.available + delta))
            return .ratio(step.split, min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound))
        }
    }
}

extension SplitNode {
    /// The horizontal splits from this node down to `split` (`split` last), each with whether
    /// `split` is the node itself or lies in its leading child. Nil when `split` is not in this
    /// tree or splits vertically; a vertical split on the way is passed through (both its children
    /// span the column's full width).
    nonisolated func horizontalPath(to split: SplitID) -> [(split: SplitID, growsLeading: Bool)]? {
        guard case let .split(id, axis, _, a, b) = self else { return nil }
        if id == split { return axis == .horizontal ? [(id, true)] : nil }
        for (child, leading) in [(a, true), (b, false)] {
            guard let rest = child.horizontalPath(to: split) else { continue }
            return axis == .horizontal ? [(id, leading)] + rest : rest
        }
        return nil
    }
}
