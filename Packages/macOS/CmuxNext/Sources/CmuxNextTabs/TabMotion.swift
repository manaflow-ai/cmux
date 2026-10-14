import CmuxNextDesign
import CoreGraphics

/// One tab's layout springs in `TabStripView` (`motion`). A tab that grows
/// in from zero width uses the `appear` spring (a new tab: `growing(at:)`); a
/// width or opacity moving to
/// zero (close, collapse) uses `disappear`; x is a position spring and never
/// does.
struct TabMotion {
    var x: Spring
    var width: Spring
    var alpha: Spring

    init(x: CGFloat, width: CGFloat, alpha: CGFloat) {
        self.x = Spring(value: x, token: .move, kind: .position)
        self.width = Spring(value: width, token: width == 0 ? .appear : .move)
        self.alpha = Spring(value: alpha, token: .appear, epsilon: 0.004)
    }

    /// A new tab growing in at `seam`, the edge where the strip shows its slot
    /// starting now, on the `move` spring of the tabs making room: its edges and
    /// theirs share one progress, so every seam stays closed (Leo 2026-10-13:
    /// from 0 to its final width as the others shrink, in one animation).
    static func growing(at seam: CGFloat) -> TabMotion {
        var motion = TabMotion(x: seam, width: 0, alpha: 0)
        motion.width.token = .move
        return motion
    }

    var isSettled: Bool { x.isSettled && width.isSettled && alpha.isSettled }

    mutating func snap() {
        x.snap()
        width.snap()
        alpha.snap()
    }
}
