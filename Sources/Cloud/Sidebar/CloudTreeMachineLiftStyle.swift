import AppKit
import QuartzCore

/// The look of a machine row while the hand holds it: a solid card in the
/// hover highlight's shape with a soft shadow, so the rows it passes over
/// never show through it.
@MainActor
enum CloudTreeMachineLiftStyle {
    private static let layerName = "cmux.machineLift.card"
    private static let fadeIn: TimeInterval = 0.12
    private static let fadeOut: TimeInterval = 0.28
    private static let shadowOpacity: Float = 0.22

    static func apply(to rowView: NSTableRowView, animated: Bool) {
        guard let host = rowView.layer else { return }
        let card = existingCard(in: host) ?? makeCard(in: host)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = cardRect(in: rowView)
        card.shadowPath = CGPath(
            roundedRect: card.bounds, cornerWidth: CloudTreeHoverStyle.cornerRadius,
            cornerHeight: CloudTreeHoverStyle.cornerRadius, transform: nil
        )
        card.backgroundColor = fill(for: rowView)
        CATransaction.commit()
        guard card.opacity != 1 else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fade(card, to: 1, duration: fadeIn)
        } else {
            card.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.opacity = 1
            CATransaction.commit()
        }
    }

    static func remove(from rowView: NSTableRowView, animated: Bool) {
        guard let host = rowView.layer, let card = existingCard(in: host), card.opacity != 0 else { return }
        if animated {
            fade(card, to: 0, duration: fadeOut)
        } else {
            card.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.opacity = 0
            CATransaction.commit()
        }
    }

    private static func existingCard(in host: CALayer) -> CALayer? {
        host.sublayers?.first { $0.name == layerName }
    }

    private static func makeCard(in host: CALayer) -> CALayer {
        let card = CALayer()
        card.name = layerName
        card.opacity = 0
        card.cornerRadius = CloudTreeHoverStyle.cornerRadius
        card.cornerCurve = .continuous
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = shadowOpacity
        card.shadowRadius = 8
        card.shadowOffset = .zero
        // Below the hover fill and the cell, above nothing: the card replaces
        // the row's transparent ground while it is lifted.
        host.insertSublayer(card, at: 0)
        return card
    }

    /// The hover highlight's horizontal extent over the full row height, so
    /// the card reads as the row's own highlight, raised.
    private static func cardRect(in rowView: NSTableRowView) -> CGRect {
        let bounds = rowView.bounds
        let leading = (rowView as? CloudTreeRowView)?.highlightLeading ?? CloudTreeHoverStyle.horizontalInset
        let x = min(leading, max(0, bounds.width - CloudTreeHoverStyle.horizontalInset))
        return CGRect(
            x: bounds.minX + x, y: bounds.minY,
            width: max(0, bounds.width - x - CloudTreeHoverStyle.horizontalInset), height: bounds.height
        )
    }

    /// The window ground with the hover shade mixed in. A selected machine's
    /// selection layer sits above the card, so it keeps reading as selected.
    private static func fill(for rowView: NSTableRowView) -> CGColor {
        var color = NSColor.windowBackgroundColor.cgColor
        rowView.effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = CloudTreeHoverStyle.hoverOpacity
            let base = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
            color = base.blended(withFraction: tint, of: .labelColor)?.cgColor ?? base.cgColor
        }
        return color
    }

    private static func fade(_ card: CALayer, to opacity: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = (card.presentation() ?? card).opacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.add(animation, forKey: "cmux.machineLift.fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = opacity
        CATransaction.commit()
    }
}
