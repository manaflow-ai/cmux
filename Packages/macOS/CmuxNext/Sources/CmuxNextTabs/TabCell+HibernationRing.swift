import AppKit
import CmuxNextDesign
import QuartzCore

/// A hibernated tab's look, as Chrome draws a discarded (Memory Saver) tab
/// (`chrome/browser/ui/views/tabs/tab/tab_icon.cc`, `dotted_icon.cc`): the
/// favicon shrinks to 14 of its 16 points and is clipped to a circle, and a
/// dotted ring fades in around it, two points outside the icon. The favicon
/// is not dimmed and the title keeps its color. Waking grows the favicon back
/// and removes the ring at once.
extension TabCell {
    /// The favicon's scale while hibernated: Chrome's 14 dp circle in a 16 dp icon.
    static let hibernatedIconScale: CGFloat = 14.0 / 16.0
    /// How far the ring sits outside the icon (Chrome `TabIcon`: `Outset(2)`).
    static let hibernationRingOutset: CGFloat = 2
    /// Chrome `DottedIcon` stroke width.
    static let hibernationRingStroke: CGFloat = 1.5

    /// Adds or removes the ring and the favicon's shrink for `item.isDormant`.
    /// `animated`: the tab just hibernated or woke while shown in the strip.
    func updateHibernationRing(animated: Bool) {
        let dormant = item.isDormant
        let iconScale = dormant ? Self.hibernatedIconScale : 1
        let transform = CATransform3DMakeScale(iconScale, iconScale, 1)
        iconLayer.masksToBounds = dormant
        if animated, let shrink = Motion.indicators.set(iconLayer, "transform", to: NSValue(caTransform3D: transform), movementFade: .hibernateIcon) {
            Self.easeIn(shrink, on: iconLayer, key: "transform")
        } else {
            iconLayer.removeAnimation(forKey: "transform")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            iconLayer.transform = transform
            CATransaction.commit()
        }
        guard dormant else {
            hibernationRingLayer?.removeFromSuperlayer()
            hibernationRingLayer = nil
            return
        }
        let ring = hibernationRingLayer ?? {
            let ring = CAShapeLayer()
            ring.actions = Self.noActions
            ring.fillColor = nil
            ring.lineCap = .round
            ring.contentsScale = scale
            layer.insertSublayer(ring, above: iconLayer)
            hibernationRingLayer = ring
            return ring
        }()
        ring.lineWidth = Self.hibernationRingStroke
        themeScope.perform { ring.strokeColor = Self.hibernationRingColor.cgColor }
        if animated, let fade = Motion.indicators.set(ring, "opacity", to: Float(1), fade: .hibernateRing, from: Float(0)) {
            Self.easeIn(fade, on: ring, key: "opacity")
        } else {
            ring.opacity = 1
        }
    }

    /// The ring's color, resolved inside the cell's theme scope. Chrome
    /// blends the inactive tab background until it is just visible; the
    /// strip's tertiary text color is the closest token here.
    static var hibernationRingColor: NSColor { Palette.textTertiary }

    /// Places the ring around `iconFrame`; hidden with the icon.
    func layoutHibernationRing(iconFrame: CGRect, visible: Bool) {
        // The icon's circle clip; its scale keeps the bounds, so the radius stays half its side.
        iconLayer.cornerRadius = item.isDormant ? iconFrame.width / 2 : 0
        guard let ring = hibernationRingLayer else { return }
        let frame = iconFrame.insetBy(dx: -Self.hibernationRingOutset, dy: -Self.hibernationRingOutset)
        ring.frame = frame
        ring.path = Self.hibernationRingPath(in: CGRect(origin: .zero, size: frame.size), stroke: Self.hibernationRingStroke)
        ring.isHidden = !visible
    }

    /// Chrome's dotted ring (`DottedIcon::PaintRingDottedPath`): one 160°
    /// arc on the leading side, then four 25° arcs with 20° gaps between
    /// all five. The circle is inset by half the stroke. The arcs are
    /// symmetric about the horizontal axis, so a flipped layer draws the
    /// same ring.
    static func hibernationRingPath(in bounds: CGRect, stroke: CGFloat) -> CGPath {
        let rect = bounds.insetBy(dx: stroke / 2, dy: stroke / 2)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        for (start, sweep) in hibernationRingArcs {
            let from = start * .pi / 180
            path.addArc(center: center, radius: radius, startAngle: from, endAngle: from + sweep * .pi / 180, clockwise: false)
        }
        return path
    }

    /// Start angle and sweep of each arc, in degrees (0 = trailing side).
    static let hibernationRingArcs: [(CGFloat, CGFloat)] = {
        let large: CGFloat = 160, smallCount = 4
        let gap = (360 - large) / 2 / CGFloat(smallCount + 1)   // 20
        let small = (360 - large) / 2 / CGFloat(smallCount)     // 25
        var arcs: [(CGFloat, CGFloat)] = [(180 - large / 2, large)]
        var start = 180 + large / 2 + gap
        for _ in 0..<smallCount {
            arcs.append((start.truncatingRemainder(dividingBy: 360), small))
            start += small + gap
        }
        return arcs
    }()

    /// Re-adds `animation` with Chrome's ease-in curve (`Tween::EASE_IN`).
    private static func easeIn(_ animation: CAAnimation, on layer: CALayer, key: String) {
        guard let copy = animation.copy() as? CABasicAnimation else { return }
        // motion-allow: Chrome's Tween::EASE_IN on a copy of a Motion.set animation (its duration and Reduce Motion stay Motion's)
        copy.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(copy, forKey: key)
    }
}
