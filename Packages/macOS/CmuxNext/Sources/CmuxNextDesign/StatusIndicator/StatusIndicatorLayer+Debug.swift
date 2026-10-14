public import CoreGraphics

public extension StatusIndicatorLayer {
    /// The square the glyph fills, in the layer's bounds (debug geometry reports).
    var debugGlyphRect: CGRect { glyphRect }

    /// The mask the layer draws its mark through, rendered for `scale` pixels per point the way
    /// the layer renders it (`StatusMarkArt.mask`); nil when the glyph is not a mark.
    func debugMarkMask(scale: CGFloat) -> CGImage? {
        guard case .mark(let mark) = plan.glyph else { return nil }
        return StatusMarkArt.mask(mark, pixels: Int((glyphRect.width * scale).rounded()))
    }
}
