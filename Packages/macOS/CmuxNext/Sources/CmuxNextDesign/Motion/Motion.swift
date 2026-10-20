public import AppKit

/// The one source of animation timing for cmux-next chrome
/// (plans/cmux-next/motion.md). Every animation reads a token here; no
/// module hard-codes a duration or spring constant
/// (`scripts/cmux-next/check-motion.sh` enforces this).
///
/// The live policy combines `DesignSettings.shared.animationSpeed`
/// (`ui.animationSpeed`) with the system Reduce Motion setting. Reading it
/// inside an Observation-tracked scope registers a dependency on the speed.
public struct Motion {
    public init() {}
    /// Tests set this to pin Reduce Motion; nil reads the system setting.
    /// A change posts `reduceMotionDidChange`, so a host that caches a value
    /// derived from `reduceMotion` (StatusIndicatorAppearance) re-reads it at
    /// once, as it does for the system setting's notification.
    public static var reduceMotionOverride: Bool? {
        didSet {
            guard reduceMotionOverride != oldValue else { return }
            NotificationCenter.default.post(name: reduceMotionDidChange, object: nil)
        }
    }

    /// Posted on the main actor when `reduceMotionOverride` changes. The
    /// system setting has its own notification
    /// (`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`).
    public static let reduceMotionDidChange = Notification.Name("CmuxNextDesign.Motion.reduceMotionDidChange")

    /// Posted on the main actor when `ui.animationSpeed` (`DesignSettings.animationSpeed`) changes.
    public static let speedDidChange = Notification.Name("CmuxNextDesign.Motion.speedDidChange")

    /// System Reduce Motion (Accessibility > Display), or the test override.
    public static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var speed: MotionSpeed { DesignSettings.shared.animationSpeed }

    public static var policy: MotionPolicy {
        let design = DesignSettings.shared
        return MotionPolicy(speed: speed, reduceMotion: reduceMotion, bounce: design.animationBounce,
                            enabledKinds: design.enabledAnimations, liveResize: isLiveResizing)
    }

    /// `kind` animates: movement animates (not `off`, not Reduce Motion, not a
    /// live resize) and its `ui.animations.*` switch is on. When false the
    /// change applies in one frame, with no crossfade.
    public static func animates(_ kind: MotionKind) -> Bool { policy.animates(kind) }

    /// Position, size, scale and scroll animate. When false, snap.
    public static var animatesMovement: Bool { policy.animatesMovement }
    /// Pane layout changes (split, close, move, swap, zoom, column reveal,
    /// screen switch) spring: `ui.paneAnimations` is on and movement
    /// animates. Off by default, so they apply in one frame; direct
    /// manipulation (trackpad fling, wheel, divider drag) keeps its physics.
    public static var animatesPaneLayout: Bool { DesignSettings.shared.paneAnimations && animatesMovement }
    /// Opacity and color changes animate.
    public static var animatesFades: Bool { policy.animatesFades }
    /// Spinners and pulses run.
    public static var animatesLoops: Bool { policy.animatesLoops }

    public static func spring(_ token: MotionSpring) -> SpringParameters { policy.spring(token) }
    public static func duration(_ token: MotionFade) -> TimeInterval { policy.duration(token) }
    public static func duration(_ token: MotionSpring) -> TimeInterval { policy.duration(token) }
    public static func period(_ loop: MotionLoop) -> TimeInterval? { policy.period(loop) }

    /// Seconds of a released divider's velocity projected to find a snap; 0
    /// when movement does not animate.
    public static var dividerReleaseProjection: Double {
        animatesMovement ? MotionTunables.dividerReleaseProjection.value * speed.timeScale : 0
    }

    /// The standard ease-out curve for timed fades.
    public static var fadeCurve: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}
