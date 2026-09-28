public import CoreGraphics

/// Pure layout for the shared-size bounds drawn on a terminal surface.
///
/// The letterbox already pins the render rect to the shared grid when this
/// phone is larger, and fills the container when it is smaller. This type
/// turns that result into what the bounds decoration draws: a border around
/// the grid, hatch in the unused container area, and a fade on each edge that
/// cuts off grid content.
public struct TerminalSizingBoundsGeometry: Equatable, Sendable {
    /// An edge of the viewport that hides grid content.
    public enum CutEdge: Equatable, Sendable {
        case trailing
        case top
    }

    /// A fade band on one cut edge.
    public struct CutFade: Equatable, Sendable {
        public let edge: CutEdge
        public let rect: CGRect
    }

    /// The width of the owner-color border, in points.
    public static let borderWidth: CGFloat = 1
    /// The depth of the amber fade on a cut edge, in points.
    public static let cutFadeDepth: CGFloat = 16

    /// The rect the border strokes, or `nil` when the viewport matches.
    public let borderRect: CGRect?
    /// Unused viewport areas outside the grid.
    public let hatchRects: [CGRect]
    /// Fade bands on edges that hide grid content, with their edge.
    public let cutFades: [CutFade]
    /// Grid columns this viewport cannot show.
    public let hiddenColumns: Int
    /// Grid rows this viewport cannot show.
    public let hiddenRows: Int

    /// Computes the layout.
    /// - Parameters:
    ///   - gridColumns: The shared grid's columns.
    ///   - gridRows: The shared grid's rows.
    ///   - viewerColumns: This phone's natural columns.
    ///   - viewerRows: This phone's natural rows.
    ///   - viewportRect: The visible terminal area in view coordinates.
    ///   - renderRect: Where the grid renders in the same coordinates.
    public init(
        gridColumns: Int,
        gridRows: Int,
        viewerColumns: Int,
        viewerRows: Int,
        viewportRect: CGRect,
        renderRect: CGRect
    ) {
        hiddenColumns = max(0, gridColumns - viewerColumns)
        hiddenRows = max(0, gridRows - viewerRows)
        let differs = gridColumns != viewerColumns || gridRows != viewerRows
        guard differs, !viewportRect.isEmpty else {
            borderRect = nil
            hatchRects = []
            cutFades = []
            return
        }
        let grid = renderRect.intersection(viewportRect)
        let visibleGrid = grid.isNull || grid.isEmpty ? viewportRect : grid
        borderRect = visibleGrid

        // The letterbox bottom-pins the grid to the dock, so unused space can
        // sit on any side; hatch every band of the viewport the grid leaves.
        let bands = [
            CGRect(x: viewportRect.minX, y: viewportRect.minY,
                   width: viewportRect.width, height: visibleGrid.minY - viewportRect.minY),
            CGRect(x: viewportRect.minX, y: visibleGrid.maxY,
                   width: viewportRect.width, height: viewportRect.maxY - visibleGrid.maxY),
            CGRect(x: viewportRect.minX, y: visibleGrid.minY,
                   width: visibleGrid.minX - viewportRect.minX, height: visibleGrid.height),
            CGRect(x: visibleGrid.maxX, y: visibleGrid.minY,
                   width: viewportRect.maxX - visibleGrid.maxX, height: visibleGrid.height),
        ]
        hatchRects = bands.filter { $0.width >= 0.5 && $0.height >= 0.5 }

        // Grid content this viewport cannot show overflows the trailing edge
        // (columns) and, because rows stay bottom-pinned, the top edge.
        var fades: [CutFade] = []
        if hiddenColumns > 0 {
            let depth = min(Self.cutFadeDepth, visibleGrid.width / 2)
            fades.append(CutFade(edge: .trailing, rect: CGRect(
                x: visibleGrid.maxX - depth,
                y: visibleGrid.minY,
                width: depth,
                height: visibleGrid.height
            )))
        }
        if hiddenRows > 0 {
            let depth = min(Self.cutFadeDepth, visibleGrid.height / 2)
            fades.append(CutFade(edge: .top, rect: CGRect(
                x: visibleGrid.minX,
                y: visibleGrid.minY,
                width: visibleGrid.width,
                height: depth
            )))
        }
        cutFades = fades
    }
}

/// What the terminal surface draws for shared sizing: the shared grid, this
/// phone's viewport, and the owner's color. `nil` on the surface draws the
/// plain letterbox.
public struct TerminalSizingBoundsDecoration: Equatable, Sendable {
    public var gridColumns: Int
    public var gridRows: Int
    public var viewerColumns: Int
    public var viewerRows: Int
    /// Owner color components in `0...1`.
    public var ownerRed: Double
    public var ownerGreen: Double
    public var ownerBlue: Double

    public init(
        gridColumns: Int,
        gridRows: Int,
        viewerColumns: Int,
        viewerRows: Int,
        ownerRed: Double,
        ownerGreen: Double,
        ownerBlue: Double
    ) {
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.viewerColumns = viewerColumns
        self.viewerRows = viewerRows
        self.ownerRed = ownerRed
        self.ownerGreen = ownerGreen
        self.ownerBlue = ownerBlue
    }

    /// The layout for this decoration in a viewport.
    /// - Parameters:
    ///   - viewportRect: The visible terminal area.
    ///   - renderRect: Where the grid renders.
    public func geometry(viewportRect: CGRect, renderRect: CGRect) -> TerminalSizingBoundsGeometry {
        TerminalSizingBoundsGeometry(
            gridColumns: gridColumns,
            gridRows: gridRows,
            viewerColumns: viewerColumns,
            viewerRows: viewerRows,
            viewportRect: viewportRect,
            renderRect: renderRect
        )
    }
}
