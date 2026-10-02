public import CoreGraphics

/// A sticky column placed at its viewport edge, in view coordinates (the
/// scroll never moves it).
public nonisolated struct StickyColumnFrame: Hashable, Sendable {
    public var column: ColumnID
    public var sticky: StickyColumn
    public var frame: CGRect
    /// What the column hides of the strip below it, in view coordinates:
    /// the band from the viewport edge to the column's inner edge (docked)
    /// or to the outer edge of its glass rim (overlay). Strip panes take no
    /// clicks or drops here and their rings never draw here.
    public var cover: CGRect
    /// The Liquid Glass rim's frame (overlay): the column plus half a gap.
    public var glass: CGRect
}

/// Splits a columns screen into the sticky columns and the scrolling strip,
/// and places them (plans/cmux-next/sticky-column.md, rules S1 to S6).
public nonisolated enum StickyStripGeometry {
    /// The largest share of the viewport one sticky column takes; with a
    /// sticky column on each edge, each takes at most `maxShareBoth`.
    public static let maxShare: CGFloat = 0.75
    public static let maxShareBoth: CGFloat = 0.4

    /// S1. The first sticky column per edge (in daemon order) holds that
    /// edge; any other sticky column scrolls. S2. A screen whose columns
    /// would all be sticky shows them all in the strip.
    public static func partition(_ columns: [LayoutColumn]) -> (left: LayoutColumn?, right: LayoutColumn?, scrolling: [LayoutColumn]) {
        var left: LayoutColumn?
        var right: LayoutColumn?
        var scrolling: [LayoutColumn] = []
        for column in columns {
            switch column.sticky?.edge {
            case .left? where left == nil: left = column
            case .right? where right == nil: right = column
            default: scrolling.append(column)
            }
        }
        guard !scrolling.isEmpty else { return (nil, nil, columns) }
        return (left, right, scrolling)
    }

    /// The strip region and the sticky frames for `viewport`.
    public struct Placement: Hashable, Sendable {
        /// Where the strip's own coordinate space starts and how wide its
        /// viewport is (view coordinates). Docked columns shrink it; overlay
        /// columns leave it full width.
        public var stripMinX: CGFloat
        public var stripWidth: CGFloat
        /// Extra strip content before the first and after the last column,
        /// so a column can scroll out from under an overlay column (S4).
        public var leadingInset: CGFloat
        public var trailingInset: CGFloat
        public var sticky: [StickyColumnFrame]

        /// The part of the strip that nothing covers (view coordinates).
        public var uncoveredMinX: CGFloat
        public var uncoveredMaxX: CGFloat
        /// Where strip panes are clipped: the uncovered range beside a
        /// docked column, the glass rim's outer edge beside an overlay.
        public var clipMinX: CGFloat
        public var clipMaxX: CGFloat
    }

    /// S3. A sticky column's width is a fraction of the whole viewport (computed
    /// like every column width), at least its panes' minimum width and
    /// at most `maxShare` of the viewport. It sits one gap from its edge.
    /// Docked: the strip starts (or ends) at the column's inner edge; the
    /// strip's own leading gap separates them. Overlay: the strip keeps the
    /// whole viewport and gets an inset of the column's width plus a gap
    /// at that end, so at rest nothing hides under it (S4).
    public static func place(
        left: (column: LayoutColumn, minimumWidth: CGFloat)?,
        right: (column: LayoutColumn, minimumWidth: CGFloat)?,
        viewport: CGSize,
        gap: CGFloat,
        scale: CGFloat = 2
    ) -> Placement {
        let share = left != nil && right != nil ? maxShareBoth : maxShare
        let widest = max(1, viewport.width * share)
        func width(_ entry: (column: LayoutColumn, minimumWidth: CGFloat)) -> CGFloat {
            let raw = ColumnStripGeometry.pixelWidth(fraction: entry.column.width, viewportWidth: viewport.width, gap: gap)
            let wanted = max(raw, entry.minimumWidth)
            return SplitGeometry.roundToPixel(min(wanted, widest), scale: scale)
        }
        var placement = Placement(stripMinX: 0, stripWidth: viewport.width, leadingInset: 0, trailingInset: 0, sticky: [],
                                  uncoveredMinX: 0, uncoveredMaxX: viewport.width, clipMinX: 0, clipMaxX: viewport.width)
        var stripMaxX = viewport.width
        if let left, let sticky = left.column.sticky {
            let w = width(left)
            let frame = CGRect(x: gap, y: 0, width: w, height: viewport.height)
            let glass = frame.insetBy(dx: -gap / 2, dy: 0).intersection(CGRect(origin: .zero, size: viewport))
            switch sticky.mode {
            case .docked:
                placement.stripMinX = frame.maxX
                placement.uncoveredMinX = frame.maxX
                placement.clipMinX = frame.maxX
            case .overlay:
                placement.leadingInset = frame.maxX
                placement.uncoveredMinX = glass.maxX
                placement.clipMinX = glass.minX
            }
            let cover = CGRect(x: 0, y: 0, width: placement.uncoveredMinX, height: viewport.height)
            placement.sticky.append(StickyColumnFrame(column: left.column.id, sticky: sticky, frame: frame, cover: cover, glass: glass))
        }
        if let right, let sticky = right.column.sticky {
            let w = width(right)
            let frame = CGRect(x: viewport.width - gap - w, y: 0, width: w, height: viewport.height)
            let glass = frame.insetBy(dx: -gap / 2, dy: 0).intersection(CGRect(origin: .zero, size: viewport))
            switch sticky.mode {
            case .docked:
                stripMaxX = frame.minX
                placement.uncoveredMaxX = frame.minX
                placement.clipMaxX = frame.minX
            case .overlay:
                placement.trailingInset = viewport.width - frame.minX
                placement.uncoveredMaxX = glass.minX
                placement.clipMaxX = glass.maxX
            }
            let cover = CGRect(x: placement.uncoveredMaxX, y: 0, width: viewport.width - placement.uncoveredMaxX, height: viewport.height)
            placement.sticky.append(StickyColumnFrame(column: right.column.id, sticky: sticky, frame: frame, cover: cover, glass: glass))
        }
        placement.stripWidth = max(1, stripMaxX - placement.stripMinX)
        return placement
    }
}
