public import CoreGraphics

/// Which part of the renderer layer shows, given its top scroll-edge band.
///
/// The drawable extends above the grid by the top band, which libghostty
/// fills with the scrollback rows just above the viewport so they dissolve
/// under the navigation bar. That only works while the grid's top row is at
/// or above the viewport's top edge. When the displayed grid starts lower (a
/// shared grid scaled to fit, or a letterbox), the band would render
/// scrollback in the unused viewport area above the grid, where the sizing
/// chrome draws its hatch and chip. The band is hidden then.
public enum TerminalScrollEdgeBandClip {
    /// The layer-local rect of the renderer layer to show, or `nil` to show
    /// all of it.
    /// - Parameters:
    ///   - layerSize: The renderer layer's bounds size (unscaled points).
    ///   - topInset: The top band's height in the same unscaled points.
    ///   - gridDisplayRect: Where the grid displays, in view coordinates.
    ///   - viewportRect: The visible terminal area, in view coordinates.
    /// - Returns: Everything from the grid's top row down, or `nil`.
    public static func visibleLayerRect(
        layerSize: CGSize,
        topInset: CGFloat,
        gridDisplayRect: CGRect,
        viewportRect: CGRect
    ) -> CGRect? {
        let tolerance: CGFloat = 0.5
        guard topInset > 0,
              !gridDisplayRect.isEmpty,
              gridDisplayRect.minY > viewportRect.minY + tolerance else {
            return nil
        }
        return CGRect(
            x: 0,
            y: topInset,
            width: layerSize.width,
            height: max(0, layerSize.height - topInset)
        )
    }
}
