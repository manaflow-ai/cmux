public import Foundation

/// Resolves motion tokens for one speed setting and Reduce Motion state.
/// Pure, so the rules are unit-tested without AppKit.
///
/// - `off`: nothing animates; every change applies in one frame.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   opacity changes stay as a short crossfade; loops stop.
/// - `normal`: every time constant is 1.5x the `fast` token.
public nonisolated struct MotionPolicy: Sendable, Equatable {
    public var speed: MotionSpeed
    public var reduceMotion: Bool

    public init(speed: MotionSpeed, reduceMotion: Bool) {
        self.speed = speed
        self.reduceMotion = reduceMotion
    }

    /// Position, size, scale and scroll animate. When false, snap.
    public var animatesMovement: Bool { speed != .off && !reduceMotion }
    /// Opacity and color changes animate. When false, apply at once.
    public var animatesFades: Bool { speed != .off }
    /// Repeating indicators (spinner, pulse) run.
    public var animatesLoops: Bool { speed != .off && !reduceMotion }

    /// The spring for `token` at this speed. Callers still snap when
    /// `animatesMovement` is false; `off` returns the `fast` spring so a
    /// caller that steps anyway never divides by zero.
    public func spring(_ token: MotionSpring) -> SpringParameters {
        speed == .off ? token.base : token.base.scaled(by: speed.timeScale)
    }

    /// Seconds for `token`; 0 means apply at once. Under Reduce Motion a fade
    /// is at most one crossfade long.
    public func duration(_ token: MotionFade) -> TimeInterval {
        guard animatesFades else { return 0 }
        let scaled = token.baseDuration * speed.timeScale
        return reduceMotion ? min(scaled, MotionFade.crossfade.baseDuration) : scaled
    }

    /// Seconds that stand in for `token` when only a timed API exists (NSWindow
    /// frames): the spring's 95% time. 0 when movement does not animate.
    public func duration(_ token: MotionSpring) -> TimeInterval {
        animatesMovement ? spring(token).perceivedDuration : 0
    }

    /// Period of `loop`, or nil when loops are stopped.
    public func period(_ loop: MotionLoop) -> TimeInterval? {
        animatesLoops ? loop.period : nil
    }
}
