public import Foundation

/// Resolves motion tokens for one speed setting and Reduce Motion state.
/// Pure, so the rules are unit-tested without AppKit.
///
/// - `off`, the master switch `ui.animations.enabled` false, or this
///   policy's ``category`` turned off: nothing animates; every change
///   applies in one frame.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   opacity changes stay as a short crossfade, at most `MotionFade.crossfade`
///   (`MotionScale.quick`, 80 ms; hover feedback is instant); loops stop.
/// - `normal`: every time constant is 1.5x the `fast` token.
/// - A live resize (a window edge under the pointer): movement is instant,
///   so each frame lays out at the window's size and nothing springs toward
///   a size the next frame replaces; fades and loops run as usual.
/// - Energy Saver (``energySaver``): ambient loops (spinners, pulses, breaths, sweeps) hold
///   still; movement, fades and the blinks a person or a notification starts run as in normal
///   mode. Chrome's battery saver throttles frame sinks the person does not interact with and
///   leaves the ones with recent input alone (chrome/browser/performance_manager/user_tuning/
///   battery_saver_mode_manager.cc, plans/cmux-next/chrome-parity/p14-energy.md, D).
public nonisolated struct MotionPolicy: Sendable, Equatable {
    public var speed: MotionSpeed
    public var reduceMotion: Bool
    /// `ui.animations.bounce`: structural springs bounce or not.
    public var bounce: MotionBounce
    /// The kinds turned on one by one (`ui.animations.*` true).
    public var enabledKinds: Set<MotionKind>
    public var liveResize: Bool
    /// `ui.animations.enabled`, the master switch: false makes every
    /// category instant, whatever its own switch says.
    public var animationsEnabled: Bool
    /// The categories whose `ui.animations.<category>` is false.
    public var disabledCategories: Set<MotionCategory>
    /// The category this policy decides for (``MotionGate``); nil decides
    /// with the master switch only (reports, the debug window).
    public var category: MotionCategory?
    /// Looping indicators ask the render server for only the frames they need (30 a second for a
    /// spinner), not the display's full rate (feature `frameRateClasses`). Never a timing change.
    public var pacesLoops: Bool
    /// Energy Saver is on (`EnergyPolicy.isSaver`, feature `energySaver`): ambient loops hold still
    /// (``animatesLoops``). Nothing else in the policy reads it, so normal mode is unchanged.
    public var energySaver: Bool

    public init(speed: MotionSpeed, reduceMotion: Bool, bounce: MotionBounce = .none,
                enabledKinds: Set<MotionKind> = [], liveResize: Bool = false,
                animationsEnabled: Bool = true, disabledCategories: Set<MotionCategory> = [],
                category: MotionCategory? = nil, pacesLoops: Bool = false, energySaver: Bool = false) {
        self.speed = speed
        self.reduceMotion = reduceMotion
        self.bounce = bounce
        self.enabledKinds = enabledKinds
        self.liveResize = liveResize
        self.animationsEnabled = animationsEnabled
        self.disabledCategories = disabledCategories
        self.category = category
        self.pacesLoops = pacesLoops
        self.energySaver = energySaver
    }

    /// This policy deciding for `category`.
    public func `for`(_ category: MotionCategory) -> MotionPolicy {
        var policy = self
        policy.category = category
        return policy
    }

    /// The master switch is on, this policy's category is on, and the speed
    /// is not "off". When false nothing in the category animates: moves,
    /// fades and loops all apply in one frame (as speed "off").
    public var categoryAnimates: Bool {
        guard animationsEnabled, speed != .off else { return false }
        guard let category else { return true }
        return !disabledCategories.contains(category)
    }

    /// Position, size, scale and scroll animate. When false, snap.
    public var animatesMovement: Bool { categoryAnimates && !reduceMotion && !liveResize }
    /// `kind` moves: movement animates and its switch is on. Off means the
    /// change applies in one frame (Reduce Motion: no crossfade either).
    public func animates(_ kind: MotionKind) -> Bool { animatesMovement && enabledKinds.contains(kind) }
    /// Opacity and color changes animate. When false, apply at once.
    public var animatesFades: Bool { categoryAnimates }
    /// Ambient repeating indicators (spinner, pulse, breath, sweep) run: not Reduce Motion and not
    /// Energy Saver. When false they show their static frame.
    public var animatesLoops: Bool { animatesBlinks && !energySaver }
    /// Blinks and repeats that end on their own or follow what the person does (an attention
    /// blink, the flash verb, dictation level bars, edit mode's wiggle) run: not Reduce Motion. Energy Saver leaves
    /// them as they are; it stills only ambient ``animatesLoops``.
    public var animatesBlinks: Bool { categoryAnimates && !reduceMotion }

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
    /// frames): the spring's visible end (within 0.5%, `perceivedDuration`).
    /// 0 when movement does not animate.
    public func duration(_ token: MotionSpring) -> TimeInterval {
        animatesMovement ? spring(token).perceivedDuration : 0
    }

    /// Period of `loop`, or nil when it is stopped: an ambient loop by ``animatesLoops``, a loop
    /// that follows the person (``MotionLoop/isAmbient`` false: the flash, the wiggle) by ``animatesBlinks``.
    public func period(_ loop: MotionLoop) -> TimeInterval? {
        (loop.isAmbient ? animatesLoops : animatesBlinks) ? loop.period : nil
    }
}
