public import CoreGraphics

/// The column strip of one screen as the scroll reducer sees it: content-space
/// column frames in order, the pane frames inside each column, the viewport
/// width and the gap. Built from `ScreenLayout` + `ScreenGeometry`, or by hand
/// in tests (for example a column wider than the viewport).
public nonisolated struct ColumnStrip: Hashable, Sendable {
    public struct Column: Hashable, Sendable {
        public var id: ColumnID
        public var frame: CGRect
        /// Pane frames of this column in content space, in layout order.
        public var panes: [PaneID]
        public var paneFrames: [PaneID: CGRect]

        public init(id: ColumnID, frame: CGRect, panes: [PaneID] = [], paneFrames: [PaneID: CGRect] = [:]) {
            self.id = id
            self.frame = frame
            self.panes = panes
            self.paneFrames = paneFrames
        }
    }

    public var columns: [Column]
    public var viewportWidth: CGFloat
    public var contentWidth: CGFloat
    public var gap: CGFloat
    /// How much of the viewport's leading and trailing ends a floating side
    /// dock covers (layout-model.md F6). Reveal, visibility and snapping
    /// measure against the uncovered window between them; 0 without one.
    public var leadingCover: CGFloat = 0
    public var trailingCover: CGFloat = 0

    /// Width of the uncovered window.
    public var visibleWidth: CGFloat { max(1, viewportWidth - leadingCover - trailingCover) }

    public init(columns: [Column], viewportWidth: CGFloat, contentWidth: CGFloat, gap: CGFloat) {
        self.columns = columns
        self.viewportWidth = viewportWidth
        self.contentWidth = contentWidth
        self.gap = gap
    }

    /// Builds the strip of a columns screen; nil for a split screen.
    public init?(layout: ScreenLayout, geometry: ScreenGeometry, gap: CGFloat) {
        guard geometry.isColumns else { return nil }
        // Docked columns never scroll: the strip is the scrolling columns only.
        let scrolling = Set(geometry.columnOrder)
        let columns = layout.columns.compactMap { column -> Column? in
            guard scrolling.contains(column.id), let frame = geometry.columns[column.id] else { return nil }
            let panes = column.root.panes
            var frames: [PaneID: CGRect] = [:]
            for pane in panes { frames[pane] = geometry.panes[pane] }
            return Column(id: column.id, frame: frame, panes: panes, paneFrames: frames)
        }
        self.init(columns: columns, viewportWidth: geometry.stripWidth, contentWidth: geometry.contentWidth, gap: gap)
        leadingCover = max(0, geometry.uncoveredMinX - geometry.stripMinX)
        trailingCover = max(0, geometry.stripMinX + geometry.stripWidth - geometry.uncoveredMaxX)
    }

    public var maxOffset: CGFloat { max(0, contentWidth - viewportWidth) }

    public func clamp(_ offset: CGFloat) -> CGFloat { min(max(offset, 0), maxOffset) }

    /// Padding: the gap, shrunk when the column is nearly as wide as the view.
    public func padding(for width: CGFloat) -> CGFloat { min(max((visibleWidth - width) / 2, 0), gap) }

    /// True when `rect` (with its padding) lies inside the viewport at `offset`.
    public func isFullyVisible(_ rect: CGRect, at offset: CGFloat) -> Bool {
        let pad = padding(for: rect.width)
        return rect.minX - pad >= offset + leadingCover - 0.5 && rect.maxX + pad <= offset + leadingCover + visibleWidth + 0.5
    }
}
