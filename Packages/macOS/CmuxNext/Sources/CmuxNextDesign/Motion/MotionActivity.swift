public import QuartzCore

/// Whether a Motion animation runs now: the in-flight signal of every gate path, which ``MotionLateCommits`` judges
/// commits during. Each animation a gate starts (an `animator()` group, a CATransaction with a duration, a layer
/// animation a gate makes, a SwiftUI gate animation) moves the end of motion to its own end, and each frame a
/// ``MotionClock`` steps keeps it two frames ahead. A repeating loop (a spinner, a pulse) has no end and is left
/// out: the render server runs it with no main-thread commit.
///
/// One time, not one entry per animation: a start is a clock read and a max, a read is one compare once motion
/// ended. It knows nothing of settling at sleep; that is ``MotionInFlight``.
@MainActor
enum MotionActivity {
    /// When the last started animation ends (`CACurrentMediaTime`); 0 once that passed.
    private(set) static var end: CFTimeInterval = 0

    /// An animation runs from now for `seconds` (no effect for 0, a negative or a non-finite time).
    static func began(seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        end = max(end, CACurrentMediaTime() + seconds)
    }

    /// `animation` about to be added now, `delay` seconds before it starts, counted until it ends; returned as is.
    @discardableResult
    static func began<Kind: CAAnimation>(_ animation: Kind, after delay: CFTimeInterval = 0) -> Kind {
        began(seconds: delay + activeSeconds(animation))
        return animation
    }

    /// How long `animation` runs: its repeat duration, else its duration times its repeats (twice when it
    /// autoreverses); infinite for a loop that repeats forever.
    static func activeSeconds(_ animation: CAAnimation) -> TimeInterval {
        if animation.repeatDuration > 0 { return animation.repeatDuration }
        let once = animation.duration * (animation.autoreverses ? 2 : 1)
        return animation.repeatCount > 0 ? once * Double(animation.repeatCount) : once
    }

    /// Forgets every started animation, so a test reads only the end its own change sets.
    static func reset() {
        end = 0
    }

    /// A Motion animation runs now.
    static var isAnimating: Bool {
        guard end > 0 else { return false }
        if CACurrentMediaTime() < end { return true }
        end = 0
        return false
    }
}
