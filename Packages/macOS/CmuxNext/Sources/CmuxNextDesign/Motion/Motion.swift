public import AppKit
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// The one source of animation timing for cmux-next chrome
/// (plans/cmux-next/motion.md). Every animation reads a token here; no
/// module hard-codes a duration or spring constant
/// (`scripts/cmux-next/check-motion.sh` enforces this).
///
/// Every animation names its ``MotionCategory`` through a gate
/// (`Motion.sidebar`, `Motion.tabs`, ...; ``MotionGate``). The gate's policy
/// combines the master switch `ui.animations.enabled`, the category's
/// `ui.animations.<category>`, `ui.animationSpeed` and the system Reduce
/// Motion setting. Reading it inside an Observation-tracked scope registers
/// a dependency on those settings, Reduce Motion included (``AppearanceSignals``);
/// an owner outside Observation subscribes to ``AppearanceSignals/Signal/motion``.
public struct Motion {
    public init() {}
    /// Tests set this to pin Reduce Motion; nil reads the system setting. It is the app's
    /// ``AppearanceSignals/reduceMotionOverride``: Observation readers re-read when it changes, and
    /// a host that caches a value derived from `reduceMotion` (StatusIndicatorAppearance) follows
    /// the signals' ``AppearanceSignals/Signal/reduceMotion``.
    public static var reduceMotionOverride: Bool? {
        get { DesignSettings.shared.signals.reduceMotionOverride }
        set { DesignSettings.shared.signals.reduceMotionOverride = newValue }
    }

    /// System Reduce Motion (Accessibility > Display) or calm mode (`ui.calm`, ``CalmMode``), or
    /// the test override. Observable: it reads ``AppearanceSignals``.
    public static var reduceMotion: Bool { reduceMotion(of: .shared) }

    /// ``reduceMotion`` with `design`'s calm mode.
    public static func reduceMotion(of design: DesignSettings) -> Bool {
        DesignSettings.shared.signals.reduceMotion(of: design)
    }

    public static var speed: MotionSpeed { DesignSettings.shared.animationSpeed }

    /// The policy before a category is chosen: the master switch
    /// `ui.animations.enabled` (calm mode `still` turns it off), the category switches, `ui.animationSpeed`,
    /// Reduce Motion, a live resize and Energy Saver (ambient loops only, ``DesignSettings/energySaver``).
    /// Animations never read it directly: they ask their category's gate (`Motion.sidebar.policy`),
    /// which adds the category.
    public static var basePolicy: MotionPolicy { basePolicy(of: .shared) }

    /// ``basePolicy`` as `design`'s settings make it. The gates read it of `DesignSettings.shared`; a reader
    /// that holds its own `DesignSettings` (the oracle's settings facet) reads it with the same rules.
    public static func basePolicy(of design: DesignSettings) -> MotionPolicy {
        MotionPolicy(speed: design.animationSpeed, reduceMotion: reduceMotion(of: design), bounce: design.animationBounce,
                     enabledKinds: design.enabledAnimations, liveResize: isLiveResizing,
                     animationsEnabled: design.animationsEnabled && !design.calmMode.stopsAnimations,
                     disabledCategories: design.disabledAnimationCategories,
                     pacesLoops: design.loopsFollowFrameRate, energySaver: design.energySaver)
    }

    // MARK: Gates, one per MotionCategory

    /// Sidebar rows and groups (``MotionCategory/sidebar``).
    public nonisolated static let sidebar = MotionGate(.sidebar)
    /// The tab strip (``MotionCategory/tabs``).
    public nonisolated static let tabs = MotionGate(.tabs)
    /// Panes and windows (``MotionCategory/panes``).
    public nonisolated static let panes = MotionGate(.panes)
    /// Menus, popovers, palette, sheets, toasts and cards (``MotionCategory/overlays``).
    public nonisolated static let overlays = MotionGate(.overlays)
    /// Hover cards and tooltips (``MotionCategory/hoverCards``).
    public nonisolated static let hoverCards = MotionGate(.hoverCards)
    /// Home and the Chief chat (``MotionCategory/home``).
    public nonisolated static let home = MotionGate(.home)
    /// The agent cursor (``MotionCategory/cursor``).
    public nonisolated static let cursor = MotionGate(.cursor)
    /// Spinners, pulses, progress and flashes (``MotionCategory/indicators``).
    public nonisolated static let indicators = MotionGate(.indicators)
    /// Hover, press, focus and color changes (``MotionCategory/feedback``).
    public nonisolated static let feedback = MotionGate(.feedback)
    /// The app's own web UI (``MotionCategory/web``).
    public nonisolated static let web = MotionGate(.web)

    /// The gate of `category`.
    public nonisolated static func gate(_ category: MotionCategory) -> MotionGate { MotionGate(category) }

    /// The standard ease-out curve for timed fades.
    public static var fadeCurve: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}

extension MotionGate {
    /// `kind` animates: movement animates (category on, not `off`, not
    /// Reduce Motion, not a live resize) and its `ui.animations.*` kind
    /// switch is on. When false the change applies in one frame, with no
    /// crossfade.
    public func animates(_ kind: MotionKind) -> Bool { policy.animates(kind) }

    /// Position, size, scale and scroll animate. When false, snap.
    public var animatesMovement: Bool { policy.animatesMovement }
    /// Pane layout changes (split, close, move, swap, zoom, column reveal,
    /// screen switch) spring: `ui.paneAnimations` is on and movement
    /// animates. Off by default, so they apply in one frame; direct
    /// manipulation (trackpad fling, wheel, divider drag) keeps its physics.
    public var animatesPaneLayout: Bool { DesignSettings.shared.paneAnimations && animatesMovement }
    /// Opacity and color changes animate.
    public var animatesFades: Bool { policy.animatesFades }
    /// Ambient spinners, pulses, breaths and sweeps run (not Reduce Motion, not Energy Saver).
    public var animatesLoops: Bool { policy.animatesLoops }
    /// Blinks a person or a notification starts, and repeats that follow the person, run (not
    /// Reduce Motion); Energy Saver leaves them as they are.
    public var animatesBlinks: Bool { policy.animatesBlinks }

    public func spring(_ token: MotionSpring) -> SpringParameters { policy.spring(token) }
    public func duration(_ token: MotionFade) -> TimeInterval { policy.duration(token) }
    public func duration(_ token: MotionSpring) -> TimeInterval { policy.duration(token) }
    /// Seconds of tween `token` in this gate's category; 0 applies at once.
    public func duration(_ token: MotionTween) -> TimeInterval { policy.duration(token) }
    public func period(_ loop: MotionLoop) -> TimeInterval? { policy.period(loop) }

    /// Seconds of a released divider's velocity projected to find a snap; 0
    /// when movement does not animate.
    public var dividerReleaseProjection: Double {
        animatesMovement ? MotionTunables.dividerReleaseProjection.value * speed.timeScale : 0
    }
}
