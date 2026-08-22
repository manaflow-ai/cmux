public import CoreGraphics

/// Pure geometry for the viewport used to position rendered terminal content.
///
/// The layout viewport is the daemon-authoritative target for the current grid.
/// The live viewport follows presentation state during keyboard animation. When
/// stale live geometry is being clamped, the layout target wins so a transient
/// one-row live measurement cannot collapse the rendered prompt row.
public struct TerminalRenderViewportGeometry {
    // Only the one-row presentation-frame glitch is stale; larger live heights are keyboard animation.
    private static let collapsedLiveViewportMaximumHeight: CGFloat = 44

    /// The layout viewport for the current terminal grid.
    public let layoutViewportRect: CGRect
    /// The transient live viewport from presentation state.
    public let liveViewportRect: CGRect

    /// Creates render viewport geometry from layout and live viewport rectangles.
    ///
    /// - Parameters:
    ///   - layoutViewportRect: The layout viewport for the current terminal grid.
    ///   - liveViewportRect: The transient live viewport from presentation state.
    public init(layoutViewportRect: CGRect, liveViewportRect: CGRect) {
        self.layoutViewportRect = layoutViewportRect
        self.liveViewportRect = liveViewportRect
    }

    /// Returns the viewport rectangle used for positioning rendered content.
    ///
    /// - Parameters:
    ///   - renderSize: The current rendered terminal content size.
    ///   - clampsStaleLiveViewport: Whether stale live geometry should be clamped.
    /// - Returns: A viewport using the layout origin and width, with height floored at 1 point.
    public func viewportRect(
        forRenderSize renderSize: CGSize,
        clampsStaleLiveViewport: Bool
    ) -> CGRect {
        let targetHeight = max(1, layoutViewportRect.height)
        let liveHeight = max(1, liveViewportRect.height)
        let height: CGFloat
        if clampsStaleLiveViewport {
            height = isCollapsedLiveViewport(
                liveHeight: liveHeight,
                targetHeight: targetHeight,
                renderHeight: renderSize.height
            ) ? targetHeight : min(liveHeight, targetHeight)
        } else {
            height = liveHeight
        }
        return CGRect(
            x: layoutViewportRect.minX,
            y: layoutViewportRect.minY,
            width: layoutViewportRect.width,
            height: height
        )
    }

    private func isCollapsedLiveViewport(
        liveHeight: CGFloat,
        targetHeight: CGFloat,
        renderHeight: CGFloat
    ) -> Bool {
        let referenceHeight = min(targetHeight, max(1, renderHeight))
        return liveHeight <= min(referenceHeight, Self.collapsedLiveViewportMaximumHeight)
    }
}
