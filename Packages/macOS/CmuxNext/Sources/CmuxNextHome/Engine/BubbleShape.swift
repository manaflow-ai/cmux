import CoreGraphics
import Foundation

/// Bubble outlines in y-down coordinates (MessagesLab `Draw.bubblePath`,
/// traced from the Messages recording and scaled to the bubble radius).
nonisolated enum BubbleShape {
    static func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        let k = min(radius, r.height / 2, r.width / 2)
        return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
    }

    /// Bubble body `r` with a tail at the bottom corner on the sender's side
    /// (right for outgoing). The tail hangs below the body by `0.27 * radius`.
    static func path(_ r: CGRect, outgoing: Bool, tail: Bool, radius: CGFloat) -> CGPath {
        let radius = min(radius, r.height / 2)
        guard tail else { return roundedRect(r, radius: radius) }
        // Reference geometry is for an 18 pt radius; scale the tail with the bubble.
        let k = radius / 18
        let p = CGMutablePath()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0, y: radius))
        p.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        p.addArc(center: CGPoint(x: w - radius, y: radius), radius: radius, startAngle: 1.5 * .pi, endAngle: 2 * .pi,
                 clockwise: false)
        let joinY = max(radius, h - 13 * k)
        p.addLine(to: CGPoint(x: w, y: joinY))
        p.addCurve(to: CGPoint(x: w - 7.75 * k, y: h + 0.4 * k),
                   control1: CGPoint(x: w, y: h - 9 * k), control2: CGPoint(x: w - 6.6 * k, y: h - 2.4 * k))
        p.addCurve(to: CGPoint(x: w - 5.6 * k, y: h + 4.8 * k),
                   control1: CGPoint(x: w - 7.9 * k, y: h + 2.0 * k), control2: CGPoint(x: w - 6.4 * k, y: h + 4.0 * k))
        p.addCurve(to: CGPoint(x: w - 17 * k, y: h),
                   control1: CGPoint(x: w - 9.2 * k, y: h + 5.0 * k), control2: CGPoint(x: w - 11.5 * k, y: h + 0.4 * k))
        p.addArc(center: CGPoint(x: radius, y: h - radius), radius: radius, startAngle: 0.5 * .pi, endAngle: .pi,
                 clockwise: false)
        p.closeSubpath()
        var t = outgoing
            ? CGAffineTransform(translationX: r.minX, y: r.minY)
            : CGAffineTransform(translationX: r.maxX, y: r.minY).scaledBy(x: -1, y: 1)
        return p.copy(using: &t) ?? roundedRect(r, radius: radius)
    }
}
