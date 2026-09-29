import AppKit
import CmuxNextDesign
import QuartzCore

// Layers a tab needs only sometimes, created on first need and removed when
// unused (architecture.md 3: 100 idle tabs cost five layers each).
extension TabCell {
    // MARK: - Lazy layers (z-order: icon, spinner, badge, title, close)

    func makeSpinner() -> CAShapeLayer {
        if let spinnerLayer { return spinnerLayer }
        let spinner = CAShapeLayer()
        spinner.actions = Self.noActions
        spinner.fillColor = nil
        spinner.lineWidth = Metrics.space1 * 0.75
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.72
        spinner.contentsScale = scale
        appearance.performAsCurrentDrawingAppearance { spinner.strokeColor = Palette.textSecondary.cgColor }
        layer.insertSublayer(spinner, above: iconLayer)
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
        appearance.performAsCurrentDrawingAppearance { badgeLayer.backgroundColor = badgeColor?.cgColor }
    }

    func makeCloseLayers() -> (background: CALayer, glyph: CAShapeLayer) {
        if let closeBackgroundLayer, let closeGlyphLayer { return (closeBackgroundLayer, closeGlyphLayer) }
        let background = CALayer()
        background.cornerCurve = .continuous
        background.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull()]
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
        appearance.performAsCurrentDrawingAppearance {
            closeGlyphLayer.strokeColor = (isCloseHovered ? Palette.textPrimary : Palette.textSecondary).cgColor
            closeBackgroundLayer.backgroundColor = isClosePressed
                ? Palette.selectionFill.cgColor
                : (isCloseHovered ? Palette.hoverFill.cgColor : nil)
        }
    }

    func removeCloseLayers() {
        closeBackgroundLayer?.removeFromSuperlayer()
        closeGlyphLayer?.removeFromSuperlayer()
        closeBackgroundLayer = nil
        closeGlyphLayer = nil
    }
}
