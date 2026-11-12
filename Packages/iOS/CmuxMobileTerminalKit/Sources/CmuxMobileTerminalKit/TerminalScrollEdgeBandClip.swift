public import CoreGraphics

/// Which part of the renderer layer shows, given its scroll-edge bands.
///
/// The drawable extends above the grid by the top band and below it by the
/// bottom band, which libghostty fills with the scrollback rows just outside
/// the viewport so they dissolve under the navigation bar and the dock. That
/// only works while the grid's edge is at or past the matching viewport
/// edge. When the displayed grid ends inside the viewport (a shared grid
/// shorter than the phone, top-pinned with its slack below; or one scaled to
/// fit), a band would render rows in the unused viewport area where the
/// sizing chrome draws its hatch and chip. That band is hidden then.
public struct TerminalScrollEdgeBandClip: Equatable, Sendable {
    /// The top band's height in unscaled points.
    public let topInset: CGFloat
    /// The bottom band's height in unscaled points.
    public let bottomInset: CGFloat

    /// Creates the clip for the renderer's applied scroll-edge bands.
    /// - Parameters:
    ///   - topInset: The top band's height in unscaled points.
    ///   - bottomInset: The bottom band's height in unscaled points.
    public init(topInset: CGFloat, bottomInset: CGFloat) {
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// The layer-local rect of the renderer layer to show, or `nil` to show
    /// all of it.
    /// - Parameters:
    ///   - layerSize: The renderer layer's bounds size (unscaled points).
    ///   - gridDisplayRect: Where the grid displays, in view coordinates.
    ///   - viewportRect: The visible terminal area, in view coordinates.
    /// - Returns: The layer without each band whose grid edge sits inside
    ///   the viewport, or `nil` when both bands show.
    public func visibleLayerRect(
        layerSize: CGSize,
        gridDisplayRect: CGRect,
        viewportRect: CGRect
    ) -> CGRect? {
        let tolerance: CGFloat = 0.5
        guard !gridDisplayRect.isEmpty else { return nil }
        let hidesTop = topInset > 0 && gridDisplayRect.minY > viewportRect.minY + tolerance
        let hidesBottom = bottomInset > 0 && gridDisplayRect.maxY < viewportRect.maxY - tolerance
        guard hidesTop || hidesBottom else { return nil }
        let top = hidesTop ? topInset : 0
        let bottom = hidesBottom ? bottomInset : 0
        return CGRect(
            x: 0,
            y: top,
            width: layerSize.width,
            height: max(0, layerSize.height - top - bottom)
        )
    }
}
