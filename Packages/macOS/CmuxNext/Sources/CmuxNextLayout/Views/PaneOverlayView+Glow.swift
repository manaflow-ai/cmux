import AppKit
import CmuxNextDesign
import QuartzCore

/// Classic's attention ring glow (origin/main `Sources/Panels/Panel.swift`,
/// `notificationRingStyle` and `flashRingStyle`): the ring glows softly in its
/// own color while it shows, and more while it flashes out.
extension PaneOverlayView {
    /// A shadow around the ring: its opacity and blur radius in points.
    struct Glow: Equatable {
        var opacity: Float
        var radius: CGFloat

        /// The ring at rest.
        static let ring = Glow(opacity: 0.35, radius: 3)
        /// The dismiss flash.
        static let flash = Glow(opacity: 0.6, radius: 6)
    }

    /// Whether the ring flashes on this pane: focus just arrived, the screen asked for the flash
    /// (`ScreenContentView.requestsFocusFlash`, which also needs motion allowed) and no ring
    /// already marks it.
    static func flashesFocus(wasFocused: Bool, focused: Bool, requested: Bool, ringShows: Bool) -> Bool {
        requested && focused && !wasFocused && !ringShows
    }

    /// The flash's stroke is at least this wide, so a 1 pt ring setting still reads at a glance.
    static let flashMinimumWidth: CGFloat = 2

    /// The resting ring's glow (for tests).
    var attentionGlow: Glow { Glow(opacity: attentionLayer.shadowOpacity, radius: attentionLayer.shadowRadius) }
    /// The glow's color (for tests).
    var attentionGlowColor: CGColor? { attentionLayer.shadowColor }
    /// The running dismiss flash's glow, nil when none runs (for tests).
    var attentionDismissGlow: Glow? {
        guard let group = attentionLayer.animation(forKey: "attention-dismiss-glow") as? CAAnimationGroup else { return nil }
        func value(_ key: String) -> NSNumber? {
            (group.animations?.first { ($0 as? CABasicAnimation)?.keyPath == key } as? CABasicAnimation)?.toValue as? NSNumber
        }
        guard let opacity = value("shadowOpacity"), let radius = value("shadowRadius") else { return nil }
        return Glow(opacity: opacity.floatValue, radius: CGFloat(radius.doubleValue))
    }

    /// Sets the resting glow on the ring layer under the `glow` ring style, none under `ring`;
    /// the color follows the ring's (`applyColors`).
    func applyRingGlow() {
        let glows = ringGlows
        attentionLayer.shadowOffset = .zero
        attentionLayer.shadowOpacity = glows ? Glow.ring.opacity : 0
        attentionLayer.shadowRadius = glows ? Glow.ring.radius : 0
    }

    /// Holds the flash glow while `flash` (the dismiss flash) runs, under the `glow` ring style.
    func addFlashGlow(for flash: CAAnimation) {
        guard ringGlows, let hold = Motion.indicators.attentionGlowHold(opacity: Glow.flash.opacity, radius: Glow.flash.radius,
                                                             duration: flash.duration) else { return }
        attentionLayer.add(hold, forKey: "attention-dismiss-glow")
    }

    /// Every corner of a layer (`maskedCorners`' default).
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// The outline a border of `width` inside a rect of `size` draws, its `corners`
    /// rounded with `radius` (as the layer's `maskedCorners`), in the layer's
    /// coordinates: the glow's shadow path, so Core Animation needs no offscreen pass to find it.
    static func ringOutline(size: CGSize, radius: CGFloat, width: CGFloat, corners: CACornerMask = allCorners) -> CGPath? {
        guard width > 0, size.width > width * 2, size.height > width * 2 else { return nil }
        let inset = CGRect(origin: .zero, size: size).insetBy(dx: width / 2, dy: width / 2)
        let corner = max(0, min(radius - width / 2, min(inset.width, inset.height) / 2))
        let path: CGPath
        if corners == allCorners || corner == 0 {
            path = CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil)
        } else {
            let shape = CGMutablePath()
            let round = { (mask: CACornerMask) in corners.contains(mask) ? corner : 0 }
            let (minX, minY, maxX, maxY) = (inset.minX, inset.minY, inset.maxX, inset.maxY)
            shape.move(to: CGPoint(x: minX + round(.layerMinXMinYCorner), y: minY))
            shape.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: round(.layerMaxXMinYCorner))
            shape.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY), radius: round(.layerMaxXMaxYCorner))
            shape.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: round(.layerMinXMaxYCorner))
            shape.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: round(.layerMinXMinYCorner))
            shape.closeSubpath()
            path = shape
        }
        return path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    }
}
