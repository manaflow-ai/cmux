import CmuxNextDesign
import CoreGraphics

/// One tab's layout motion in `TabStripView` (`motion`): Chrome's model
/// (design-tokens.json `motion.tweens`). x and width are tweens: 200 ms
/// 1-(1-t)^2 from where they are on screen, restarted by a new target, never
/// by the same one. Alpha is a spring, used only by a collapsing group's
/// members (Chrome's open and close never fade).
struct TabMotion {
    var x: TabTween
    var width: TabTween
    var alpha: Spring

    init(x: CGFloat, width: CGFloat, alpha: CGFloat) {
        self.x = TabTween(x)
        self.width = TabTween(width)
        self.alpha = Spring(value: alpha, token: .appear, epsilon: 0.004)
    }

    var isSettled: Bool { x.isSettled && width.isSettled && alpha.isSettled }

    /// Both geometry tweens take `token` for their next target (open, close, move).
    mutating func use(_ token: MotionTween) {
        x.token = token
        width.token = token
    }

    mutating func snap() {
        x.snap()
        width.snap()
        alpha.snap()
    }
}

/// A tab's x or width on a tween token. Setting `target` restarts the
/// token's duration (`Motion.duration`, 0 under Reduce Motion, speed off, a
/// live resize, or open/close with `ui.animations.newTab` off) from the
/// value on screen; the same target is a no-op.
struct TabTween {
    private var tween: TweenValue
    /// The token the next new target uses.
    var token: MotionTween

    init(_ value: CGFloat, token: MotionTween = .tabMove) {
        tween = TweenValue(value, token: token)
        self.token = token
    }

    var value: CGFloat { tween.value }
    var isSettled: Bool { tween.isSettled }

    var target: CGFloat {
        get { tween.target }
        set { tween.retarget(newValue, duration: Motion.duration(token), token: token) }
    }

    /// Advances `dt` seconds. True while still moving.
    @discardableResult
    mutating func step(_ dt: CGFloat) -> Bool { tween.step(Double(dt)) }

    mutating func snap() { tween.snap() }
    mutating func snap(to target: CGFloat) { tween.snap(to: target) }

    /// Direct manipulation (a dragged tab under the pointer): exactly `value`, no lag.
    mutating func follow(_ value: CGFloat) { tween.snap(to: value) }
}
