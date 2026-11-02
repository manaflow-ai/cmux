public import CoreGraphics

/// The column strip of one screen as the scroll reducer reads it: content-space
/// column frames in order, the pane frames inside each column, the viewport
/// width and the gap. Built from `ScreenLayout` + `ScreenGeometry`, or by hand
/// in tests (for example a column wider than the viewport).
///
/// Only the reducer's input: the rules that read it (reveal, centering, the
/// camera anchor, snapping) are Rust's, cmux-layout-reducer `scroll`, behind
/// ``ColumnScrollState/reduce(_:)``.
public nonisolated struct ColumnStrip: Hashable, Sendable {
    /// One column of the strip.
    public struct Column: Hashable, Sendable {
        /// The column's identity: the camera anchors on it across snapshots.
        public var id: ColumnID
        /// The column's content-space frame.
        public var frame: CGRect
        /// Pane frames of this column in content space, in layout order.
        public var panes: [PaneID]
        /// Each pane's content-space frame.
        public var paneFrames: [PaneID: CGRect]

        /// A column with its panes.
        public init(id: ColumnID, frame: CGRect, panes: [PaneID] = [], paneFrames: [PaneID: CGRect] = [:]) {
            self.id = id
            self.frame = frame
            self.panes = panes
            self.paneFrames = paneFrames
        }
    }

    /// The columns, leading to trailing.
    public var columns: [Column]
    /// Width of the viewport the strip shows through.
    public var viewportWidth: CGFloat
    /// Width of the laid-out strip.
    public var contentWidth: CGFloat
    /// The gap before, between and after the columns.
    public var gap: CGFloat
    /// The presentation axis before transposition; row cameras animate without horizontal carry compensation.
    public var axis: SplitAxis = .horizontal
    /// How much of the viewport's leading and trailing ends a floating side
    /// dock covers (layout-model.md F6). Reveal, visibility and snapping
    /// measure against the uncovered window between them; 0 without one.
    public var leadingCover: CGFloat = 0
    /// See ``leadingCover``.
    public var trailingCover: CGFloat = 0
    /// Where the adapters' strips start: a row stack's min y (``RowScroll``), a
    /// scroll area's window min x (``ScrollAreaScroll``). The reducer transposes
    /// and shifts those strips itself.
    var origin: CGFloat = 0

    /// A strip of these columns.
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
}
