public import AppKit

/// The Liquid Glass tint of a window backdrop moving to a new color with the color transition
/// (`appearance.colorTransition`, cx-3rf4z). `NSGlassEffectView.tintColor` is not a layer
/// property Core Animation can interpolate, so the window's ``MotionClock`` steps it: each frame
/// sets the color at the curve's progress (cmux-motion), from the color on screen when it
/// retargets. Instant transitions and windows not on screen set it at once.
@MainActor
final class GlassTintBlend: MotionAnimating {
    private weak var glass: GlassPanelView?
    private var from = ThemeRGB(red: 0, green: 0, blue: 0, alpha: 0)
    private var to = ThemeRGB(red: 0, green: 0, blue: 0, alpha: 0)
    private var elapsed: TimeInterval = 0
    private var transition = ColorTransition(enabled: false)

    /// Moves `glass`'s tint to `color` (nil clears it at once).
    func set(_ glass: GlassPanelView, to color: NSColor?, in view: NSView) {
        let current = glass.tintColor.flatMap(Self.rgb)
        guard let color, let target = Self.rgb(color) else {
            MotionClock.forView(view).stop(self)
            glass.tintColor = color
            return
        }
        let transition = ColorTransition.current
        guard view.window?.isVisible == true, !transition.isInstant, let current, current != target else {
            MotionClock.forView(view).stop(self)
            glass.tintColor = color
            return
        }
        if self.glass === glass, to == target { return }
        self.glass = glass
        (from, to, elapsed, self.transition) = (current, target, 0, transition)
        MotionClock.forView(view).run(self, trace: "colorTransition.glassTint")
    }

    func motionStep(_ dt: Double) -> Bool {
        guard let glass else { return false }
        elapsed += dt
        let seconds = transition.seconds
        let t = seconds > 0 ? min(elapsed / seconds, 1) : 1
        let color = transition.mix(from, to, fraction: transition.progress(at: t))
        glass.tintColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        return t < 1
    }

    private static func rgb(_ color: NSColor) -> ThemeRGB? {
        ColorTransition.rgb(color.cgColor)
    }
}
