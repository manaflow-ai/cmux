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

    /// Casts `layer`'s shadow from the band its border draws (its bounds, corner radius and border
    /// width), built only when one of them changed: no offscreen pass to find the border's alpha.
    static func castBorderShadow(_ layer: CALayer) {
        let size = layer.bounds.size, radius = layer.cornerRadius, width = layer.borderWidth
        layer.cast(shadowPathFor: [size.width, size.height, radius, width]) { ringOutline(size: size, radius: radius, width: width) }
    }

    /// The chrome rides a render-server spring (`PaneOverlayView+RenderSpring`), which Core Animation
    /// does not apply to a shadow path: the glowing rings' outlines follow their springing sizes
    /// frame by frame instead, so their glow stays on the presented border. Each `update` until the ride
    /// ends (``ridesRenderSpring``) does it again, for a glow that starts to show on the way.
    func followRideShadows() {
        ridesRenderSpring = true
        for (glowing, shownBy) in [(attentionLayer, attentionLayer), (glowLayer, glowLayer.superlayer ?? glowLayer)] {
            // A glow that does not show (another ring style, no mark) has no outline to follow.
            guard shownBy.opacity > 0 || (shownBy.presentation()?.opacity ?? 0) > 0 else {
                glowing.stopFollowingShadowPath()
                continue
            }
            let radius = glowing.cornerRadius, width = glowing.borderWidth
            glowing.followShadowPath { Self.ringOutline(size: $0, radius: radius, width: width) }
        }
    }

    /// The ride ended early (`stopRide`): the outlines are at rest with the springs.
    func stopFollowingRideShadows() {
        for glowing in [attentionLayer, glowLayer] { glowing.stopFollowingShadowPath() }
    }

    /// The band a border of `width` draws inside a rounded rect of `size`, in the layer's coordinates:
    /// the glow's shadow path.
    static func ringOutline(size: CGSize, radius: CGFloat, width: CGFloat) -> CGPath? {
        ShadowOutline(size: size, cornerRadius: radius).band(width: width)
    }
}
