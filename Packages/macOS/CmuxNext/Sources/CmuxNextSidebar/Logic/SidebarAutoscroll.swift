import CoreGraphics

/// Edge auto-scroll during a drag: a pure speed curve. The display link runs
/// only while this returns a nonzero velocity, so a drag parked mid-list
/// costs no frames.
enum SidebarAutoscroll {
    /// Scroll velocity in points per second (negative scrolls up) for a
    /// pointer at `pointY` in a viewport spanning `visibleMinY...visibleMaxY`
    /// (flipped coordinates). Zero outside the `zone`-high edge bands; eases
    /// in quadratically, reaching `maxSpeed` at the edge and up to 4x that
    /// when the pointer overshoots by a full zone.
    static func velocity(pointY: CGFloat, visibleMinY: CGFloat, visibleMaxY: CGFloat, zone: CGFloat, maxSpeed: CGFloat) -> CGFloat {
        guard zone > 0, visibleMaxY > visibleMinY else { return 0 }
        let fromTop = pointY - visibleMinY
        let fromBottom = visibleMaxY - pointY
        if fromTop < zone, fromTop <= fromBottom {
            return -pow((zone - max(fromTop, -zone)) / zone, 2) * maxSpeed
        }
        if fromBottom < zone {
            return pow((zone - max(fromBottom, -zone)) / zone, 2) * maxSpeed
        }
        return 0
    }
}
