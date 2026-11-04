import QuartzCore

/// The left bar beside a group's member rows (the group rail, `GroupLineView`): one capsule, the same round cap at
/// the top and the bottom (Lawrence msg 19775: "roundness of left bar needs to be better, like rounded on both top
/// and bottom"). The rail's layer clips a flat body to these corners, so the caps follow the layer's presentation
/// bounds through every frame of the rows' spring (a drawn path would keep the model height and cut a cap off).
enum SidebarGroupLineShape {
    /// Every corner rounds: the top cap and the bottom cap are the same.
    static let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// Half the bar's width: a full semicircle at each end (Core Animation clamps it on a rail shorter than wide).
    static func cornerRadius(width: CGFloat) -> CGFloat { max(0, width) / 2 }

    /// The flat body the rail's clipping layer rounds: a plain rectangle.
    static func body(width: CGFloat, height: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: 0, y: 0, width: max(0, width), height: max(0, height)), transform: nil)
    }
}
