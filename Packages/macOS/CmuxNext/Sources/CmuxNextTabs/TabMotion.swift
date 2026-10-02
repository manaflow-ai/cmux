import CmuxNextDesign
import CoreGraphics

/// One tab's layout springs in `TabStripView` (`motion`). A tab that grows
/// in from zero width uses the `appear` spring; a move to zero (close,
/// collapse) uses `disappear`.
struct TabMotion {
    var x: Spring
    var width: Spring
    var alpha: Spring

    init(x: CGFloat, width: CGFloat, alpha: CGFloat) {
        self.x = Spring(value: x, token: .move)
        self.width = Spring(value: width, token: width == 0 ? .appear : .move)
        self.alpha = Spring(value: alpha, token: .appear, epsilon: 0.004)
    }

    var isSettled: Bool { x.isSettled && width.isSettled && alpha.isSettled }

    mutating func snap() {
        x.snap()
        width.snap()
        alpha.snap()
    }
}
