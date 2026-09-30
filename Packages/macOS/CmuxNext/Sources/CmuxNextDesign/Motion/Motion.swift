public import AppKit

/// The one source of animation timing for cmux-next chrome
/// (plans/cmux-next/motion.md). Every animation reads a token here; no
/// module hard-codes a duration or spring constant
/// (`scripts/cmux-next/check-motion.sh` enforces this).
///
/// The live policy combines `DesignSettings.shared.animationSpeed`
/// (`ui.animationSpeed`) with the system Reduce Motion setting. Reading it
/// inside an Observation-tracked scope registers a dependency on the speed.
public enum Motion {
    /// Tests set this to pin Reduce Motion; nil reads the system setting.
    public static var reduceMotionOverride: Bool?

    /// System Reduce Motion (Accessibility > Display), or the test override.
    public static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var speed: MotionSpeed { DesignSettings.shared.animationSpeed }

    public static var policy: MotionPolicy { MotionPolicy(speed: speed, reduceMotion: reduceMotion) }

    /// Position, size, scale and scroll animate. When false, snap.
    public static var animatesMovement: Bool { policy.animatesMovement }
    /// Opacity and color changes animate.
    public static var animatesFades: Bool { policy.animatesFades }
    /// Spinners and pulses run.
    public static var animatesLoops: Bool { policy.animatesLoops }

    public static func spring(_ token: MotionSpring) -> SpringParameters { policy.spring(token) }
    public static func duration(_ token: MotionFade) -> TimeInterval { policy.duration(token) }
    public static func duration(_ token: MotionSpring) -> TimeInterval { policy.duration(token) }
    public static func period(_ loop: MotionLoop) -> TimeInterval? { policy.period(loop) }

    /// The standard ease-out curve for timed fades.
    public static var fadeCurve: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}
