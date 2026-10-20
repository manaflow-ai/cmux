public import CoreGraphics
import QuartzCore

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

public extension StatusIndicatorLayer {
    /// How far the spinning glyph is through its turn now, 0..<1, from its presentation (debug
    /// reports: synced spinners read the same value at the same moment); nil when it is still.
    var debugRotationPhase: Double? {
        guard let running = runningAnimation, [.spin, .step].contains(running),
              let target = running == .step ? nativeLayer : glyphLayer,
              let transform = target.presentation()?.transform else { return nil }
        let angle = Double(atan2(transform.m12, transform.m11))
        let turn = -angle / (2 * Double.pi)
        return ((turn.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 1000).rounded() / 1000
    }
}
