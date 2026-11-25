import QuartzCore

/// The left bar beside a group's member rows (the group rail, `GroupLineView`), in the rail's flipped y-down
/// coordinates: a capsule, both ends rounded by half its width (Lawrence 2026-11-17: "group left bar is not pixel
/// perfect, it needs proper even roundness"; the katana's one-sided tip of 2026-11-08 read as a lopsided top). The
/// rounding is the rail layer's corner clip, so it follows the layer's presentation bounds through every frame of the
/// rows' spring; the body is a plain bar. A `joined` rail (the solid band's one shape with its header) keeps its top
/// square, where it runs out of the bar.
enum SidebarGroupLineShape {
    /// The clip's rounded corners: all four, or the bottom two for a rail that joins its header's bar (`flipped`: the
    /// layer's y runs down).
    static func capCorners(flipped: Bool, joined: Bool = false) -> CACornerMask {
        let bottom: CACornerMask = flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        guard !joined else { return bottom }
        return [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    /// Half the bar's width: a full semicircle at each end (Core Animation clamps it on a rail shorter than wide).
    static func cornerRadius(width: CGFloat) -> CGFloat { max(0, width) / 2 }

    /// The body the rail's clipping layer rounds: a plain bar.
    static func body(width: CGFloat, height: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: 0, y: 0, width: max(0, width), height: max(0, height)), transform: nil)
    }
}
