import CoreGraphics

/// The Messages bubble outline, shared by the iOS and macOS surfaces. Paths
/// use top-left-origin coordinates (UIKit, or a flipped AppKit view).
public enum ConversationBubbleGeometry {
    public enum Side: Sendable {
        case leading
        case trailing
    }

    /// `rect` includes the tail area on `side` whether or not a tail is drawn,
    /// so tailed and tailless bubbles in a run share one body edge. A tailed
    /// bubble also draws `tailDrop` below `rect`.
    public static func path(
        in rect: CGRect,
        side: Side,
        tail: Bool,
        radius: CGFloat,
        tailWidth: CGFloat,
        tailDrop: CGFloat
    ) -> CGPath {
        var body = rect
        body.size.width -= tailWidth
        if side == .leading { body.origin.x += tailWidth }
        let r = max(0, min(radius, body.height / 2, body.width / 2))
        guard tail else {
            return CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        var transform = side == .leading
            ? CGAffineTransform(translationX: rect.maxX, y: rect.minY).scaledBy(x: -1, y: 1)
            : CGAffineTransform(translationX: rect.minX, y: rect.minY)
        let path = trailingTailPath(width: body.width, height: body.height, radius: r, tailWidth: tailWidth, tailDrop: tailDrop)
        return path.copy(using: &transform) ?? path
    }

    /// Body spans x in [0, width] and y in [0, height]. The tail leaves the
    /// bottom edge near the corner, curls out past the right edge, and drops
    /// `tailDrop` below the body to a softly rounded tip.
    private static func trailingTailPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, tailWidth t: CGFloat, tailDrop d: CGFloat) -> CGPath {
        let k: CGFloat = 0.4477 // control-point factor approximating a quarter circle
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addCurve(to: CGPoint(x: w, y: r), control1: CGPoint(x: w - r * k, y: 0), control2: CGPoint(x: w, y: r * k))
        p.addLine(to: CGPoint(x: w, y: max(r, h - r * 0.55)))
        // Outer edge of the tail: a concave sweep from the side down to the tip.
        let tip = CGPoint(x: w + t * 0.95, y: h + d)
        p.addCurve(to: tip, control1: CGPoint(x: w, y: h - r * 0.05), control2: CGPoint(x: w - 1.5, y: h + d * 0.55))
        // Rounded tip, then the inner edge back into the bottom of the body.
        p.addCurve(to: CGPoint(x: w - 4, y: h + d - 1.2), control1: CGPoint(x: w + t * 0.95 + 0.6, y: h + d + 0.9), control2: CGPoint(x: w - 2.2, y: h + d - 0.2))
        p.addCurve(to: CGPoint(x: w - r * 1.05, y: h), control1: CGPoint(x: w - 7, y: h + d * 0.55), control2: CGPoint(x: w - r * 0.65, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - r), control1: CGPoint(x: r * k, y: h), control2: CGPoint(x: 0, y: h - r * k))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: 0, y: r * k), control2: CGPoint(x: r * k, y: 0))
        p.closeSubpath()
        return p
    }
}
