public import CoreGraphics
import Foundation

/// Places rendered terminal boxes within a live viewport.
///
/// The placement policy separates intentional effective-grid letterboxing from
/// stale natural renders that are waiting for an async viewport resize echo.
public struct TerminalRenderPlacement: Sendable {
    /// Vertical slack above which an intentional effective-grid letterbox is
    /// anchored to the viewport top instead of bottom-attached.
    public let largeTopGapThreshold: CGFloat

    /// Creates a terminal render-placement policy.
    ///
    /// - Parameter largeTopGapThreshold: Vertical slack threshold in points.
    public init(largeTopGapThreshold: CGFloat = 48) {
        self.largeTopGapThreshold = largeTopGapThreshold
    }

    /// Position a rendered terminal box inside the live viewport.
    ///
    /// The renderer should keep small whole-cell remainder attached to the bottom
    /// chrome, but a substantially shorter intentional letterbox must not be
    /// bottom-pinned: that produces a large blank region above the terminal when
    /// opening directly into a smaller effective grid. Oversized render boxes
    /// remain bottom-pinned so keyboard-show shrink clips from the top instead of
    /// hiding the prompt/input edge.
    ///
    /// - Parameters:
    ///   - viewport: The terminal viewport in host-view coordinates.
    ///   - size: The rendered terminal box size in points.
    ///   - allowsLargeTopGapCorrection: True when this render size is known to
    ///     come from an effective-grid letterbox. False keeps stale natural
    ///     renders bottom-attached during live viewport transitions.
    /// - Returns: The render rectangle in host-view coordinates.
    public func renderRect(
        in viewport: CGRect,
        size: CGSize,
        allowsLargeTopGapCorrection: Bool = true
    ) -> CGRect {
        let renderSize = CGSize(
            width: max(1, size.width),
            height: max(1, size.height)
        )
        let verticalSlack = viewport.height - renderSize.height
        let y = allowsLargeTopGapCorrection && verticalSlack > max(0, largeTopGapThreshold)
            ? viewport.minY
            : viewport.maxY - renderSize.height
        return CGRect(
            x: viewport.minX,
            y: y,
            width: renderSize.width,
            height: renderSize.height
        )
    }

    /// Decide whether a pinned render should use the large-gap top-anchor
    /// correction.
    ///
    /// A pinned grid is usually an intentional effective-grid letterbox, but
    /// during local viewport growth the Mac may still be echoing the old local
    /// grid while a larger viewport report is pending. In that stale case the
    /// render must remain bottom-attached so the prompt stays against the
    /// toolbar until the authoritative echo for the new natural grid arrives.
    ///
    /// - Parameters:
    ///   - pinnedGrid: The effective grid used to compute the pinned render, or
    ///     `nil` when the render is natural/full-container.
    ///   - awaitingViewportEcho: The larger local natural grid waiting for a
    ///     daemon echo.
    ///   - naturalGrid: The natural grid measured for the current viewport.
    ///   - previousRenderAllowedTopGapCorrection: Whether the previous render
    ///     was already known to be an intentional top-corrected letterbox.
    /// - Returns: True when large-slack top anchoring is allowed.
    public func allowsLargeTopGapCorrection(
        pinnedGrid: (cols: Int, rows: Int)?,
        awaitingViewportEcho: (cols: Int, rows: Int)?,
        naturalGrid: (cols: Int, rows: Int),
        previousRenderAllowedTopGapCorrection: Bool
    ) -> Bool {
        guard let pinnedGrid else { return false }
        guard !previousRenderAllowedTopGapCorrection else { return true }
        guard let awaitingViewportEcho else { return true }

        let awaitingGridOutgrowsPinned =
            awaitingViewportEcho.cols > pinnedGrid.cols ||
            awaitingViewportEcho.rows > pinnedGrid.rows
        let currentNaturalReachedAwaitingGrid =
            naturalGrid.cols >= awaitingViewportEcho.cols &&
            naturalGrid.rows >= awaitingViewportEcho.rows
        return !(awaitingGridOutgrowsPinned && currentNaturalReachedAwaitingGrid)
    }

    /// Map a pointer location to the rendered terminal grid.
    ///
    /// Points in the letterbox margin are outside the terminal and should not be
    /// forwarded as mouse or scroll-wheel events.
    ///
    /// - Parameters:
    ///   - point: Pointer location in host-view coordinates.
    ///   - renderRect: Rendered terminal rectangle in host-view coordinates.
    ///   - cellSize: Terminal cell size in points.
    /// - Returns: The grid cell under `point`, or `nil` outside `renderRect`.
    public func gridCell(
        at point: CGPoint,
        in renderRect: CGRect,
        cellSize: CGSize
    ) -> (col: Int, row: Int)? {
        guard !renderRect.isEmpty,
              point.x >= renderRect.minX,
              point.x < renderRect.maxX,
              point.y >= renderRect.minY,
              point.y < renderRect.maxY else {
            return nil
        }
        let cellW = max(cellSize.width, 1)
        let cellH = max(cellSize.height, 1)
        let col = max(0, Int((point.x - renderRect.minX) / cellW))
        let row = max(0, Int((point.y - renderRect.minY) / cellH))
        return (col, row)
    }
}
