import AppKit
import CmuxNextDesign
import QuartzCore

/// The theme's accent glow (`appearance.accentGlow.*`, `ThemeFlourishes.Glow`): a soft light of
/// the theme's color around the focused pane's content area, outside it only (a mask keeps it off
/// the content). It shows on the focused pane (by keyboard or click), `focusRing.enabled` or not.
/// No glow set: no layer exists and the overlay is today's.
extension PaneOverlayView {
    /// The glow's layer, made the first time a glow is set (below the overlay's other layers).
    private func accentGlowLayerIfNeeded() -> CALayer? {
        if let accentGlowLayer { return accentGlowLayer }
        guard accentGlow != nil, let root = layer else { return nil }
        let glowLayer = CALayer()
        glowLayer.opacity = 0
        glowLayer.shadowOffset = .zero
        glowLayer.isHidden = !showsContentFrame
        root.insertSublayer(glowLayer, at: 0)
        accentGlowLayer = glowLayer
        return glowLayer
    }

    /// Frames the glow on the ring's rect (`layoutLayers`, inside its action-free transaction).
    func layoutAccentGlow(rect: CGRect, radius: CGFloat) {
        guard let glow = accentGlow, let glowLayer = accentGlowLayerIfNeeded() else { return }
        glowLayer.frame = rect
        glowLayer.shadowRadius = glow.radius
        glowLayer.shadowOpacity = Float(glow.opacity)
        let size = rect.size
        let corner = max(0, min(radius, min(size.width, size.height) / 2))
        let shape = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: corner, cornerHeight: corner, transform: nil)
        // Given, so Core Animation needs no offscreen pass to find the shadow.
        glowLayer.shadowPath = shape
        // Outside only: the mask covers the glow's reach, less the content area.
        let spill = glow.radius * 3 + 1
        let reach = CGRect(origin: .zero, size: size).insetBy(dx: -spill, dy: -spill)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: reach.size))
        path.addPath(shape, transform: CGAffineTransform(translationX: spill, y: spill))
        let mask = (glowLayer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = reach
        mask.path = path
        if glowLayer.mask !== mask { glowLayer.mask = mask }
    }

    /// Shows the glow on the focused pane; as the ring, one leaving goes at once and one
    /// arriving eases in.
    func applyAccentGlowOpacity(shows: Bool, animated: Bool) {
        guard let glowLayer = accentGlowLayerIfNeeded() else { return }
        let value: Float = shows ? 1 : 0
        guard value != glowLayer.opacity else { return }
        if value < glowLayer.opacity {
            Motion.panes.transaction(nil) {
                glowLayer.removeAnimation(forKey: "opacity")
                glowLayer.opacity = value
            }
        } else {
            Motion.feedback.transaction(animated ? .focus : nil) { glowLayer.opacity = value }
        }
    }

    /// The glow's color for this view's appearance (`applyColors`, inside `performWithTheme`).
    func applyAccentGlowColor() {
        guard let glow = accentGlow, let accentGlowLayer else { return }
        accentGlowLayer.shadowColor = glow.color(dark: themeTokens.isDark).nsColor.cgColor
    }
}
