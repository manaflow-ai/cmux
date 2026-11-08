import QuartzCore

extension StatusIndicatorLayer {
    /// The keys of the settle's two one-shot animations.
    static let settleScaleKey = "settle.scale"
    static let settleTintKey = "settle.tint"

    /// Settles the glyph in once: it grows from `settleScale` to full size while its color eases
    /// from the accent to its own (`Motion.indicators.settleAnimation`, the `settle` fade). Both
    /// animations remove themselves when they end; with movement off (Reduce Motion, the switches)
    /// the gate gives none and the glyph simply shows. The host decides when (a state transition,
    /// on a visible window, ``StatusIndicatorView/settle()``).
    public func playSettle() {
        guard plan.glyph != .none, let scale = Motion.indicators.settleAnimation("transform.scale", from: Self.settleScale) else { return }
        layer.add(scale, forKey: Self.settleScaleKey)
        guard let colors, let accent = colors.working ?? colors.accent, let (target, keyPath) = tintTarget,
              let tint = Motion.indicators.settleAnimation(keyPath, from: accent) else { return }
        target.add(tint, forKey: Self.settleTintKey)
    }

    /// Ends a settle still playing, so the glyph shows its own size and color at once.
    func cancelSettle() {
        layer.removeAnimation(forKey: Self.settleScaleKey)
        tintTarget?.0.removeAnimation(forKey: Self.settleTintKey)
    }

    /// The scale a settle starts from.
    static let settleScale: CGFloat = 0.6

    /// The layer and color key path the glyph's tint draws in (`applyColors`); nil for glyphs a
    /// settle does not tint (spinner masks, the dots).
    private var tintTarget: (CALayer, String)? {
        if let markLayer { return (markLayer, "backgroundColor") }
        guard let glyphLayer else { return nil }
        return (glyphLayer, plan.glyph == .dot ? "fillColor" : "strokeColor")
    }
}
