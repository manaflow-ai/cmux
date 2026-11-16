import QuartzCore

/// The left bar beside a group's member rows (the group rail, `GroupLineView`), in the rail's flipped y-down
/// coordinates. Its top is the katana: the left edge runs straight up to a point and the right edge curves out of it,
/// a blade's tip under the header (Leo 2026-11-08: "that top tip area, it looks like a knife. You know what? I'll just
/// call it the katana. It's good. We need to add it."; Chrome's cut, "not as extreme as the Google one"). Its bottom
/// keeps the round cap (Lawrence msg 19775). The cap is the rail layer's corner clip, so it follows the layer's
/// presentation bounds through every frame of the rows' spring; the tip is drawn in the body's path at y 0, which a
/// spring never moves.
enum SidebarGroupLineShape {
    /// The bottom cap's corners: the two at the rail's bottom (`flipped`: the layer's y runs down).
    static func capCorners(flipped: Bool) -> CACornerMask {
        flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    /// Half the bar's width: a full semicircle at the bottom (Core Animation clamps it on a rail shorter than wide).
    static func cornerRadius(width: CGFloat) -> CGFloat { max(0, width) / 2 }

    /// How far down the right edge the tip's curve runs: twice the bar's width, a subtle blade, not a flare.
    static func tipLength(width: CGFloat) -> CGFloat { max(0, width) * 2 }

    /// The body the rail's clipping layer rounds at the bottom: square on the left, the katana's tip at the top right.
    static func body(width: CGFloat, height: CGFloat) -> CGPath {
        let width = max(0, width), height = max(0, height)
        let tip = min(tipLength(width: width), height)
        let path = CGMutablePath()
        path.move(to: .zero)
        // Convex, as a blade's tip: the edge leaves the point heading right and meets the right side going straight down.
        if tip > 0 { path.addQuadCurve(to: CGPoint(x: width, y: tip), control: CGPoint(x: width, y: 0)) }
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}
