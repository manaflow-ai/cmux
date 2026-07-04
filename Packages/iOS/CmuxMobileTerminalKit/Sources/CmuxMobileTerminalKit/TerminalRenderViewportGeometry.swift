public import CoreGraphics

/// Pure geometry for the viewport used to position rendered terminal content.
///
/// The layout viewport is the daemon-authoritative target for the current grid.
/// The live viewport follows presentation state during keyboard animation. When
/// stale live geometry is being clamped, the layout target wins so a transient
/// one-row live measurement cannot collapse the rendered prompt row.
public struct TerminalRenderViewportGeometry {
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
    /// - Parameter clampsStaleLiveViewport: Whether stale live geometry should be clamped.
    /// - Returns: A viewport using the layout origin and width, with height floored at 1 point.
    public func viewportRect(clampsStaleLiveViewport: Bool) -> CGRect {
        let targetHeight = max(1, layoutViewportRect.height)
        let liveHeight = max(1, liveViewportRect.height)
        return CGRect(
            x: layoutViewportRect.minX,
            y: layoutViewportRect.minY,
            width: layoutViewportRect.width,
            height: clampsStaleLiveViewport ? targetHeight : liveHeight
        )
    }
}
