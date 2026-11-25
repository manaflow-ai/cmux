import AppKit
import CmuxNextDesign
import QuartzCore

// Layers a tab needs only sometimes, created on first need and removed when
// unused (architecture.md 3: 100 idle tabs cost five layers each).
extension TabCell {
    // MARK: - Lazy layers (z-order: icon, spinner, badge, title, close)

    /// The shared status indicator in the icon slot, created while the tab
    /// is busy (`StatusIndicatorLayer`, the same one sidebar rows draw).
    func makeSpinner() -> StatusIndicatorLayer {
        if let spinnerLayer { return spinnerLayer }
        let spinner = StatusIndicatorLayer()
        spinner.hostIsFlipped = true // the strip's tab layers live in a FlippedView
        spinner.contentsScale = scale
        themeScope.perform { spinner.colors = .current(loading: StatusIndicatorAppearance.shared.config.settings.color) }
        layer.insertSublayer(spinner.layer, above: iconLayer)
        spinnerLayer = spinner
        return spinner
    }

    func makeBadge() -> CALayer {
        if let badgeLayer { return badgeLayer }
        let badge = CALayer()
        badge.actions = Self.noActions
        layer.insertSublayer(badge, below: titleLayer)
        badgeLayer = badge
        applyBadgeColor()
        return badge
    }

    func applyBadgeColor() {
        guard let badgeLayer else { return }
        themeScope.perform { badgeLayer.backgroundColor = badgeColor?.cgColor }
    }

    func makeCloseLayers() -> (background: CALayer, glyph: CAShapeLayer) {
        if let closeBackgroundLayer, let closeGlyphLayer { return (closeBackgroundLayer, closeGlyphLayer) }
        let background = CALayer()
        background.cornerCurve = .continuous
        background.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()] // Helium: no fade
        let glyph = CAShapeLayer()
        glyph.actions = Self.noActions
        glyph.fillColor = nil
        glyph.lineWidth = Metrics.space1 * 0.65
        glyph.lineCap = .round
        glyph.contentsScale = scale
        layer.insertSublayer(background, above: titleLayer)
        layer.insertSublayer(glyph, above: background)
        closeBackgroundLayer = background
        closeGlyphLayer = glyph
        applyCloseColors()
        return (background, glyph)
    }

    func applyCloseColors() {
        guard let closeBackgroundLayer, let closeGlyphLayer else { return }
        themeScope.perform {
            // Helium (Chromium's tab_close_button.cc): the x is the title's color, hovered or not; the hover fill is the
            // tab's most-contrasting ink at 16 % (pressed 14 %), shown at once.
            closeGlyphLayer.strokeColor = (isSelected ? Palette.textPrimary : Palette.textSecondary).cgColor
            // The `disc` treatment draws the fill while the x stands in for the status, so it reads as a button there.
            let disc = metrics.hoverCloseSwap == .disc && visibility.closeReplacesStatus
            let percent = BrowserChromeTuning.value(.closeHoverOpacity) - (isClosePressed ? 2 : 0)
            closeBackgroundLayer.backgroundColor = isCloseHovered || disc || isClosePressed
                ? Palette.textPrimary.withAlphaComponent(max(0, percent) / 100).cgColor : nil
        }
    }

    func removeCloseLayers() {
        closeBackgroundLayer?.removeFromSuperlayer()
        closeGlyphLayer?.removeFromSuperlayer()
        closeBackgroundLayer = nil
        closeGlyphLayer = nil
    }

    /// The close button's x: two diagonals across `glyph`.
    static func closeGlyphPath(in glyph: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
        path.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
        path.move(to: CGPoint(x: glyph.maxX, y: glyph.minY))
        path.addLine(to: CGPoint(x: glyph.minX, y: glyph.maxY))
        return path
    }
}
