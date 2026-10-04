public import CmuxNextDesign
public import CoreGraphics

/// A dock placed at its viewport edge, in view coordinates (the scroll never
/// moves it). Left and right docks are sticky columns; top and bottom docks
/// are bands.
public nonisolated struct StickyColumnFrame: Hashable, Sendable {
    public var column: ColumnID
    public var sticky: StickyColumn
    public var frame: CGRect
    /// What the dock hides of the strip below it, in view coordinates: the
    /// band from the viewport edge to the dock's inner edge (docked) or to
    /// the outer edge of its glass rim (overlay). Strip panes take no clicks
    /// or drops here and their rings never draw here.
    public var cover: CGRect
    /// The Liquid Glass rim's frame (overlay): the dock plus half a gap.
    public var glass: CGRect
}

/// Splits a columns screen into its docks and the scrolling strip, and places
/// them (plans/cmux-next/sticky-column.md S1 to S6 for left and right;
/// plans/cmux-next/layout-model.md F1 to F5 for four edges and orientation).
public nonisolated enum StickyStripGeometry {
    /// The largest share of the viewport width one side dock takes; with a
    /// dock on each side, each takes at most `maxShareBoth`.
    public static let maxShare: CGFloat = 0.75
    public static let maxShareBoth: CGFloat = 0.4
    /// The same for the height of top and bottom docks (F3).
    public static let maxBandShare: CGFloat = 0.5
    public static let maxBandShareBoth: CGFloat = 1.0 / 3.0
    /// The narrowest scrolling strip docked side docks leave, in points (at
    /// most half the viewport): docked side docks shrink to keep it, so a
    /// dock on each side never squeezes the strip's tab titles away
    /// (dogfood 2026-10-03: 170 pt with two 40% docks).
    public static let minimumStripWidth: CGFloat = 400

    /// The docks of a screen and its scrolling columns.
    public struct Parts: Sendable {
        public var left: LayoutColumn?
        public var right: LayoutColumn?
        public var top: LayoutColumn?
        public var bottom: LayoutColumn?
        public var scrolling: [LayoutColumn]

        public func dock(_ edge: StickyEdge) -> LayoutColumn? {
            switch edge {
            case .left: left
            case .right: right
            case .top: top
            case .bottom: bottom
            }
        }
    }

    /// S1. The first dock per edge (in daemon order) holds that edge; any
    /// other column marked for that edge scrolls. S2. A screen whose columns
    /// would all be docks shows them all in the strip.
    public static func partition(_ columns: [LayoutColumn]) -> (left: LayoutColumn?, right: LayoutColumn?, scrolling: [LayoutColumn]) {
        let parts = docks(columns)
        return (parts.left, parts.right, parts.scrolling)
    }

    /// `partition` for all four edges.
    public static func docks(_ columns: [LayoutColumn]) -> Parts {
        var parts = Parts(scrolling: [])
        for column in columns {
            switch column.sticky?.edge {
            case .left? where parts.left == nil: parts.left = column
            case .right? where parts.right == nil: parts.right = column
            case .top? where parts.top == nil: parts.top = column
            case .bottom? where parts.bottom == nil: parts.bottom = column
            default: parts.scrolling.append(column)
            }
        }
        guard !parts.scrolling.isEmpty else { return Parts(scrolling: columns) }
        return parts
    }

    /// The strip region and the dock frames for `viewport`.
    public struct Placement: Hashable, Sendable {
        /// Where the strip's own coordinate space starts and how wide its
        /// viewport is (view coordinates). Docked side docks shrink it;
        /// overlay side docks leave it full width.
        public var stripMinX: CGFloat
        public var stripWidth: CGFloat
        /// The strip's vertical range (view coordinates): every strip column
        /// lays out in it. Top and bottom docks move it, in either mode (an
        /// overlay band insets the columns so nothing is covered at rest).
        public var stripMinY: CGFloat = 0
        public var stripHeight: CGFloat = 0
        /// Extra strip content before the first and after the last column,
        /// so a column can scroll out from under an overlay side dock (S4).
        public var leadingInset: CGFloat
        public var trailingInset: CGFloat
        public var sticky: [StickyColumnFrame]

        /// The part of the strip that nothing covers (view coordinates).
        public var uncoveredMinX: CGFloat
        public var uncoveredMaxX: CGFloat
        public var uncoveredMinY: CGFloat = 0
        public var uncoveredMaxY: CGFloat = 0
        /// Where strip panes are clipped: the uncovered range beside a
        /// docked dock, the glass rim's outer edge beside an overlay.
        public var clipMinX: CGFloat
        public var clipMaxX: CGFloat
        public var clipMinY: CGFloat = 0
        public var clipMaxY: CGFloat = 0
    }

    /// One dock to place: its column and its panes' minimum extent (width
    /// for a side dock, height for a band).
    public typealias Dock = (column: LayoutColumn, minimumExtent: CGFloat)

    /// Left and right only (sticky-column.md S3, S4).
    public static func place(left: Dock?, right: Dock?, viewport: CGSize, gap: CGFloat, scale: CGFloat = 2) -> Placement {
        place(left: left, right: right, top: nil, bottom: nil, viewport: viewport, gap: gap, orientation: .columnMajor, scale: scale)
    }

    /// S3. A side dock's width is a fraction of the whole viewport width (the
    /// column width formula), at least its panes' minimum width and at
    /// most `maxShare` of the viewport; a band's height is the same fraction
    /// of the viewport height, capped by `maxBandShare` (F3). A dock sits one
    /// gap from its edge on its own axis. Docked: the strip ends at the dock's
    /// inner edge. Overlay: a side dock leaves the strip full width with an
    /// inset at that end (S4); an overlay band insets the strip's columns at
    /// that edge, so at rest nothing hides under it.
    ///
    /// F1. Orientation decides the corners: column-major runs the side docks
    /// the full height and puts the bands between their inner edges;
    /// row-major runs the bands the full width and puts the side docks
    /// between them, in either mode, so no dock hides another. Extents are
    /// the same in both.
    public static func place(left: Dock?, right: Dock?, top: Dock?, bottom: Dock?, viewport: CGSize, gap: CGFloat,
                             orientation: FrameOrientation, scale: CGFloat = 2) -> Placement {
        let size = CGRect(origin: .zero, size: viewport)
        // A dock without a sticky value is not a dock.
        let left = left?.column.sticky == nil ? nil : left
        let right = right?.column.sticky == nil ? nil : right
        let top = top?.column.sticky == nil ? nil : top
        let bottom = bottom?.column.sticky == nil ? nil : bottom
        let sideShare = left != nil && right != nil ? maxShareBoth : maxShare
        let bandShare = top != nil && bottom != nil ? maxBandShareBoth : maxBandShare
        func extent(_ dock: Dock, along length: CGFloat, share: CGFloat) -> CGFloat {
            let raw = ColumnStripGeometry.pixelWidth(fraction: dock.column.width, viewportWidth: length, gap: gap)
            let widest = max(1, length * share)
            return SplitGeometry.roundToPixel(min(max(raw, dock.minimumExtent), widest), scale: scale)
        }
        var leftWidth = left.map { extent($0, along: viewport.width, share: sideShare) }
        var rightWidth = right.map { extent($0, along: viewport.width, share: sideShare) }
        let topHeight = top.map { extent($0, along: viewport.height, share: bandShare) }
        let bottomHeight = bottom.map { extent($0, along: viewport.height, share: bandShare) }
        func docked(_ dock: Dock?) -> Bool { dock?.column.sticky?.mode == .docked }
        // Docked side docks shrink in proportion so the strip keeps
        // `minimumStripWidth` (at most half the viewport).
        let dockedLeft = docked(left) ? leftWidth : nil
        let dockedRight = docked(right) ? rightWidth : nil
        let used = (dockedLeft ?? 0) + (dockedRight ?? 0)
        let gaps = gap * CGFloat([dockedLeft, dockedRight].compactMap { $0 }.count)
        let room = viewport.width - min(minimumStripWidth, viewport.width / 2) - gaps
        if used > 0, used > room, room > 0 {
            let factor = room / used
            if dockedLeft != nil { leftWidth = leftWidth.map { SplitGeometry.roundToPixel($0 * factor, scale: scale) } }
            if dockedRight != nil { rightWidth = rightWidth.map { SplitGeometry.roundToPixel($0 * factor, scale: scale) } }
        }

        // The strip: docked docks take space, overlay docks inset (S4, F2).
        var placement = Placement(stripMinX: 0, stripWidth: viewport.width, leadingInset: 0, trailingInset: 0, sticky: [],
                                  uncoveredMinX: 0, uncoveredMaxX: viewport.width, clipMinX: 0, clipMaxX: viewport.width)
        var stripMaxX = viewport.width
        var stripMinY: CGFloat = 0
        var stripMaxY = viewport.height
        var uncoveredMinY: CGFloat = 0
        var uncoveredMaxY = viewport.height
        var clipMinY: CGFloat = 0
        var clipMaxY = viewport.height
        if let leftWidth {
            let inner = gap + leftWidth
            if docked(left) {
                placement.stripMinX = inner
                placement.uncoveredMinX = inner
                placement.clipMinX = inner
            } else {
                placement.leadingInset = inner
                placement.uncoveredMinX = inner + gap / 2
                placement.clipMinX = gap / 2
            }
        }
        if let rightWidth {
            let inner = viewport.width - gap - rightWidth
            if docked(right) {
                stripMaxX = inner
                placement.uncoveredMaxX = inner
                placement.clipMaxX = inner
            } else {
                placement.trailingInset = viewport.width - inner
                placement.uncoveredMaxX = inner - gap / 2
                placement.clipMaxX = viewport.width - gap / 2
            }
        }
        if let topHeight {
            // Strip panes have no gap above them, so a band adds its own.
            stripMinY = topHeight + gap
            uncoveredMinY = docked(top) ? stripMinY : topHeight + gap / 2
            clipMinY = docked(top) ? stripMinY : 0
        }
        if let bottomHeight {
            stripMaxY = viewport.height - bottomHeight - gap
            uncoveredMaxY = docked(bottom) ? stripMaxY : viewport.height - bottomHeight - gap / 2
            clipMaxY = docked(bottom) ? stripMaxY : viewport.height
        }
        placement.stripWidth = max(1, stripMaxX - placement.stripMinX)
        placement.stripMinY = stripMinY
        placement.stripHeight = max(1, stripMaxY - stripMinY)
        placement.uncoveredMinY = uncoveredMinY
        placement.uncoveredMaxY = uncoveredMaxY
        placement.clipMinY = clipMinY
        placement.clipMaxY = clipMaxY

        // The docks' lengths: column-major sides run the full height and bands
        // sit between the sides' inner edges; row-major bands run the full
        // width and sides sit between the bands' inner edges. A dock never
        // covers another dock, whatever the owners' mode: floating changes
        // only what the strip does.
        let sideMinY = orientation == .rowMajor ? topHeight.map { $0 + gap } ?? 0 : 0
        let sideMaxY = orientation == .rowMajor ? bottomHeight.map { viewport.height - $0 - gap } ?? viewport.height : viewport.height
        let bandMinX = orientation == .columnMajor ? leftWidth.map { gap + $0 + gap } ?? gap : gap
        let bandMaxX = orientation == .columnMajor ? rightWidth.map { viewport.width - gap - $0 - gap } ?? viewport.width - gap : viewport.width - gap
        func entry(_ dock: Dock, frame: CGRect, cover: CGRect) -> StickyColumnFrame? {
            guard let sticky = dock.column.sticky else { return nil }
            let glass = frame.insetBy(dx: -gap / 2, dy: -gap / 2).intersection(size)
            return StickyColumnFrame(column: dock.column.id, sticky: sticky, frame: frame, cover: cover, glass: glass)
        }
        var frames: [StickyColumnFrame?] = []
        let sideHeight = max(0, sideMaxY - sideMinY)
        let bandWidth = max(0, bandMaxX - bandMinX)
        if let left, let leftWidth {
            let frame = CGRect(x: gap, y: sideMinY, width: leftWidth, height: sideHeight)
            frames.append(entry(left, frame: frame, cover: CGRect(x: 0, y: sideMinY, width: placement.uncoveredMinX, height: frame.height)))
        }
        if let right, let rightWidth {
            let frame = CGRect(x: viewport.width - gap - rightWidth, y: sideMinY, width: rightWidth, height: sideHeight)
            let coverX = placement.uncoveredMaxX
            frames.append(entry(right, frame: frame, cover: CGRect(x: coverX, y: sideMinY, width: viewport.width - coverX, height: frame.height)))
        }
        let bandCoverMinX = orientation == .columnMajor ? placement.uncoveredMinX : 0
        let bandCoverMaxX = orientation == .columnMajor ? placement.uncoveredMaxX : viewport.width
        if let top, let topHeight {
            let frame = CGRect(x: bandMinX, y: 0, width: bandWidth, height: topHeight)
            frames.append(entry(top, frame: frame, cover: CGRect(x: bandCoverMinX, y: 0, width: bandCoverMaxX - bandCoverMinX, height: uncoveredMinY)))
        }
        if let bottom, let bottomHeight {
            let frame = CGRect(x: bandMinX, y: viewport.height - bottomHeight, width: bandWidth, height: bottomHeight)
            frames.append(entry(bottom, frame: frame, cover: CGRect(x: bandCoverMinX, y: uncoveredMaxY, width: bandCoverMaxX - bandCoverMinX,
                                                                    height: viewport.height - uncoveredMaxY)))
        }
        placement.sticky = frames.compactMap { $0 }
        return placement
    }

    /// The docks that own the frame's corners and draw above the others (F4).
    public static func ownsCorners(_ edge: StickyEdge, orientation: FrameOrientation) -> Bool {
        orientation == .columnMajor ? !edge.isBand : edge.isBand
    }
}
