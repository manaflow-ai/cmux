import AppKit
import CmuxNextDesign
import QuartzCore

/// The group underline plus a faint wash behind member tabs, from the chip's
/// pill to the last member's trailing edge. Drawn behind the tab layers.
final class TabGroupBandCell {
    let washLayer = CALayer()
    let lineLayer = CALayer()
    var color: GroupColor { didSet { if oldValue != color { updateColors() } } }
    var themeScope: ThemeScope = .app { didSet { updateColors() } }

    init(color: GroupColor) {
        self.color = color
        let none: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
        washLayer.actions = none
        lineLayer.actions = none
        washLayer.cornerCurve = .continuous
        lineLayer.cornerCurve = .continuous
        washLayer.zPosition = -1
        // Above lifted (dragged) tabs so a dragged group keeps its underline.
        lineLayer.zPosition = 12
        updateColors()
    }

    func addTo(_ parent: CALayer) {
        parent.addSublayer(washLayer)
        parent.addSublayer(lineLayer)
    }

    func remove() {
        washLayer.removeFromSuperlayer()
        lineLayer.removeFromSuperlayer()
    }

    /// `span` covers the group from its chip to its last member, in the
    /// clip layer's coordinates. Collapsed groups pass a zero-width line.
    func apply(span: CGRect, lineWidth: CGFloat, lineHeight: CGFloat, cornerRadius: CGFloat, opacity: Float) {
        washLayer.frame = span
        washLayer.cornerRadius = cornerRadius
        washLayer.opacity = opacity
        lineLayer.frame = CGRect(x: span.minX, y: span.maxY - lineHeight, width: max(0, lineWidth), height: lineHeight)
        lineLayer.cornerRadius = lineHeight / 2
        lineLayer.opacity = lineWidth > 0.5 ? opacity : 0
    }

    private func updateColors() {
        themeScope.perform {
            washLayer.backgroundColor = color.wash.cgColor
            lineLayer.backgroundColor = color.swatch.cgColor
        }
    }
}
