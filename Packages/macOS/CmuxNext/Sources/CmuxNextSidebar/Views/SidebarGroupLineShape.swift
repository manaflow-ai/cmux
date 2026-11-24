import CmuxNextDesign
import QuartzCore

/// The left bar beside a group's member rows (the group rail, `GroupLineView`), in the rail's flipped y-down
/// coordinates: a capsule, both ends rounded by half its width (Lawrence 2026-11-17: "group left bar is not pixel
/// perfect, it needs proper even roundness"; the katana's one-sided tip of 2026-11-08 read as a lopsided top). The
/// rounding is the rail layer's corner clip, so it follows the layer's presentation bounds through every frame of the
/// rows' spring; the body is a plain bar. A `joined` rail (the solid band's one shape with its header) keeps its top
/// square, where it runs out of the bar.
///
/// `sidebar.groupBarShape` Tapered (opt-in; Leo 2026-10-23: "keep the left thing but I like the cut ... just make the
/// cut the taper on the bar") draws the katana instead: the left edge runs straight up to a point and the right edge
/// curves out of it, and only the bottom keeps the round cap. The tip is drawn in the body's path at y 0, which a
/// spring never moves.
enum SidebarGroupLineShape {
    /// The clip's rounded corners: all four, or the bottom two for a rail that joins its header's bar or tapers to its
    /// tip (`flipped`: the layer's y runs down).
    static func capCorners(flipped: Bool, joined: Bool = false, shape: SidebarGroupBarShape = .rounded) -> CACornerMask {
        let bottom: CACornerMask = flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        guard !joined, shape == .rounded else { return bottom }
        return [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    /// Half the bar's width: a full semicircle at each end (Core Animation clamps it on a rail shorter than wide).
    static func cornerRadius(width: CGFloat) -> CGFloat { max(0, width) / 2 }

    /// How far down the right edge the tapered tip's curve runs: twice the bar's width, a subtle blade, not a flare.
    static func tipLength(width: CGFloat) -> CGFloat { max(0, width) * 2 }

    /// The body the rail's clipping layer rounds: a plain bar, or under Tapered (a rail not joined to its bar) the bar
    /// with the tip at the top right.
    static func body(width: CGFloat, height: CGFloat, shape: SidebarGroupBarShape = .rounded, joined: Bool = false) -> CGPath {
        let width = max(0, width), height = max(0, height)
        guard shape == .tapered, !joined else {
            return CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        }
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
