public import CoreGraphics

/// Pure layout for the shared-size bounds drawn on a terminal surface.
///
/// The surface renders the exact shared grid: pinned 1:1 when this phone is
/// larger, and scaled to fit the width when it is smaller (magnified and
/// panned by a pinch). This type turns the displayed render rect into what
/// the bounds decoration draws: a border around the visible grid, hatch in
/// the unused viewport area, and a fade on each viewport edge that cuts off
/// grid content.
public struct TerminalSizingBoundsGeometry: Equatable, Sendable {
    /// An edge of the viewport that hides grid content.
    public enum CutEdge: Equatable, Sendable {
        case leading
        case trailing
        case top
        case bottom
    }

    /// A fade band on one cut edge.
    public struct CutFade: Equatable, Sendable {
        public let edge: CutEdge
        public let rect: CGRect
    }

    /// The width of the neutral border, in points.
    public static let borderWidth: CGFloat = 1
    /// The depth of the neutral fade on a cut edge, in points.
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

        // A fade marks each viewport edge the displayed grid runs past.
        let tolerance: CGFloat = 0.5
        let widthDepth = min(Self.cutFadeDepth, visibleGrid.width / 2)
        let heightDepth = min(Self.cutFadeDepth, visibleGrid.height / 2)
        var fades: [CutFade] = []
        if renderRect.maxX > viewportRect.maxX + tolerance {
            fades.append(CutFade(edge: .trailing, rect: CGRect(
                x: visibleGrid.maxX - widthDepth, y: visibleGrid.minY,
                width: widthDepth, height: visibleGrid.height
            )))
        }
        if renderRect.minX < viewportRect.minX - tolerance {
            fades.append(CutFade(edge: .leading, rect: CGRect(
                x: visibleGrid.minX, y: visibleGrid.minY,
                width: widthDepth, height: visibleGrid.height
            )))
        }
        if renderRect.minY < viewportRect.minY - tolerance {
            fades.append(CutFade(edge: .top, rect: CGRect(
                x: visibleGrid.minX, y: visibleGrid.minY,
                width: visibleGrid.width, height: heightDepth
            )))
        }
        if renderRect.maxY > viewportRect.maxY + tolerance {
            fades.append(CutFade(edge: .bottom, rect: CGRect(
                x: visibleGrid.minX, y: visibleGrid.maxY - heightDepth,
                width: visibleGrid.width, height: heightDepth
            )))
        }
        cutFades = fades
    }
}

/// What the terminal surface draws for shared sizing: the shared grid and
/// this phone's viewport. The chrome is neutral grey. `nil` on the surface
/// means the host publishes no size state, and the surface draws the plain
/// letterbox.
public struct TerminalSizingBoundsDecoration: Equatable, Sendable {
    public var gridColumns: Int
    public var gridRows: Int
    public var viewerColumns: Int
    public var viewerRows: Int
    /// Whether the host's newest size state lists this phone's latest
    /// acknowledged viewport. `false` while the state still describes an
    /// older viewport, so the grid mismatch may be transient.
    public var viewportConfirmed: Bool

    public init(
        gridColumns: Int,
        gridRows: Int,
        viewerColumns: Int,
        viewerRows: Int,
        viewportConfirmed: Bool = true
    ) {
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.viewerColumns = viewerColumns
        self.viewerRows = viewerRows
        self.viewportConfirmed = viewportConfirmed
    }

    /// Whether the grid differs from this phone's viewport.
    public var viewportDiffers: Bool {
        gridColumns != viewerColumns || gridRows != viewerRows
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
