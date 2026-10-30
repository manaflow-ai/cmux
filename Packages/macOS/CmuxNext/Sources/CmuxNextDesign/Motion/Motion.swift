public import AppKit
public import CmuxNextDesignTokens

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
/// a dependency on those settings.
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

    /// Posted on the main actor when `ui.animationSpeed` (`DesignSettings.animationSpeed`), the
    /// master switch `ui.animations.enabled` or a category switch changes.
    public static let speedDidChange = Notification.Name("CmuxNextDesign.Motion.speedDidChange")

    /// System Reduce Motion (Accessibility > Display) or calm mode (`ui.calm`, ``CalmMode``), or
    /// the test override.
    public static var reduceMotion: Bool {
        reduceMotionOverride ?? (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || DesignSettings.shared.calmMode.reducesMotion)
    }

    public static var speed: MotionSpeed { DesignSettings.shared.animationSpeed }

    /// The policy before a category is chosen: the master switch
    /// `ui.animations.enabled` (calm mode `still` turns it off), the category switches, `ui.animationSpeed`,
    /// Reduce Motion and a live resize. Animations never read it directly:
    /// they ask their category's gate (`Motion.sidebar.policy`), which adds
    /// the category.
    public static var basePolicy: MotionPolicy {
        let design = DesignSettings.shared
        return MotionPolicy(speed: speed, reduceMotion: reduceMotion, bounce: design.animationBounce,
                            enabledKinds: design.enabledAnimations, liveResize: isLiveResizing,
                            animationsEnabled: design.animationsEnabled && !design.calmMode.stopsAnimations,
                            disabledCategories: design.disabledAnimationCategories)
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
    /// Spinners and pulses run.
    public var animatesLoops: Bool { policy.animatesLoops }

    public func spring(_ token: MotionSpring) -> SpringParameters { policy.spring(token) }
    public func duration(_ token: MotionFade) -> TimeInterval { policy.duration(token) }
    public func duration(_ token: MotionSpring) -> TimeInterval { policy.duration(token) }
    public func period(_ loop: MotionLoop) -> TimeInterval? { policy.period(loop) }

    /// Seconds of a released divider's velocity projected to find a snap; 0
    /// when movement does not animate.
    public var dividerReleaseProjection: Double {
        animatesMovement ? MotionTunables.dividerReleaseProjection.value * speed.timeScale : 0
    }
}
