public import Foundation

/// Resolves motion tokens for one speed setting and Reduce Motion state.
/// Pure, so the rules are unit-tested without AppKit.
///
/// - `off`: nothing animates; every change applies in one frame.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   opacity changes stay as a short crossfade (hover feedback is
///   instant); loops stop.
/// - `normal`: every time constant is 1.5x the `fast` token.
/// - A live resize (a window edge under the pointer): movement is instant,
///   so each frame lays out at the window's size and nothing springs toward
///   a size the next frame replaces; fades and loops run as usual.
public nonisolated struct MotionPolicy: Sendable, Equatable {
    public var speed: MotionSpeed
    public var reduceMotion: Bool
    /// `ui.animations.bounce`: structural springs bounce or not.
    public var bounce: MotionBounce
    /// The kinds turned on one by one (`ui.animations.*` true).
    public var enabledKinds: Set<MotionKind>
    public var liveResize: Bool

    public init(speed: MotionSpeed, reduceMotion: Bool, bounce: MotionBounce = .none,
                enabledKinds: Set<MotionKind> = [], liveResize: Bool = false) {
        self.speed = speed
        self.reduceMotion = reduceMotion
        self.bounce = bounce
        self.enabledKinds = enabledKinds
        self.liveResize = liveResize
    }

    /// Position, size, scale and scroll animate. When false, snap.
    public var animatesMovement: Bool { speed != .off && !reduceMotion && !liveResize }
    /// `kind` moves: movement animates and its switch is on. Off means the
    /// change applies in one frame (Reduce Motion: no crossfade either).
    public func animates(_ kind: MotionKind) -> Bool { animatesMovement && enabledKinds.contains(kind) }
    /// Opacity and color changes animate. When false, apply at once.
    public var animatesFades: Bool { speed != .off }
    /// Repeating indicators (spinner, pulse) run.
    public var animatesLoops: Bool { speed != .off && !reduceMotion }

    /// The spring for `token` at this speed. Callers still snap when
    /// `animatesMovement` is false; `off` returns the `fast` spring so a
    /// caller that steps anyway never divides by zero.
    public func spring(_ token: MotionSpring) -> SpringParameters {
        var base = token.base
        if token.isStructural {
            // Bounce none: critically damped (never past the target); subtle: SwiftUI bounce.
            base = bounce == .subtle ? base.withBounce(MotionTunables.subtleBounce.value)
                : SpringParameters(response: base.response, dampingFraction: max(base.dampingFraction, 1))
        }
        return speed == .off ? base : base.scaled(by: speed.timeScale)
    }

    /// Seconds for `token`; 0 means apply at once. Under Reduce Motion a fade
    /// is at most one crossfade long, and hover feedback is instant.
    public func duration(_ token: MotionFade) -> TimeInterval {
        guard animatesFades, !(reduceMotion && (token == .hover || token == .hoverReveal || token == .hoverOut)) else { return 0 }
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
