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
    /// A change posts `reduceMotionDidChange` and tells ``changes``, so a host that caches a value
    /// derived from `reduceMotion` (StatusIndicatorAppearance) re-reads it at
    /// once, as it does for the system setting's notification.
    public static var reduceMotionOverride: Bool? {
        didSet {
            guard reduceMotionOverride != oldValue else { return }
            changes.post(.reduceMotion)
        }
    }

    /// The app's one subscription to every motion-setting change, the system Reduce Motion
    /// included (``MotionChanges``).
    public static var changes: MotionChanges { DesignSettings.shared.motionChanges }

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
    /// `ui.animations.enabled` (calm mode `still` turns it off), the category switches, `ui.animationSpeed`
    /// and Reduce Motion. Animations never read it directly: they ask their category's gate
    /// (`Motion.sidebar.policy(in: window)`), which adds the category and the window's live resize.
    public static var basePolicy: MotionPolicy {
        let design = DesignSettings.shared
        return MotionPolicy(speed: speed, reduceMotion: reduceMotion,
                            enabledKinds: design.enabledAnimations,
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
    /// `kind` animates in `window`: movement animates there (category on, not `off`, not
    /// Reduce Motion, `window` not in a live resize) and its `ui.animations.*` kind
    /// switch is on. When false the change applies in one frame, with no
    /// crossfade.
    public func animates(_ kind: MotionKind, in window: NSWindow?) -> Bool { policy(in: window).animates(kind) }

    /// Position, size, scale and scroll animate, for a motion that no resized window shows (a
    /// panel's own open or close, a drag ghost, a value a page keeps). When false, snap. A
    /// motion inside an app window asks ``animatesMovement(in:)``.
    public var animatesMovement: Bool { policy.animatesMovement }
    /// Position, size, scale and scroll animate in `window`. False also while `window` is in a
    /// live resize or a full screen transition (``policy(in:)``): its content follows the edge in
    /// every frame. A resize of another window changes nothing here.
    public func animatesMovement(in window: NSWindow?) -> Bool { policy(in: window).animatesMovement }
    /// Pane layout changes (split, close, move, swap, zoom, column reveal)
    /// spring in `window`: `ui.paneAnimations` is on (the default) and movement
    /// animates there. Off, they apply in one frame; direct manipulation
    /// (trackpad fling, wheel, divider drag) keeps its physics. A change of
    /// screen is not in this set: it never animates (`LayoutRootView.showScreen`).
    public func animatesPaneLayout(in window: NSWindow?) -> Bool {
        DesignSettings.shared.paneAnimations && animatesMovement(in: window)
    }
    /// Opacity and color changes animate.
    public var animatesFades: Bool { policy.animatesFades }
    /// Spinners and pulses run.
    public var animatesLoops: Bool { policy.animatesLoops }

    public func spring(_ token: MotionSpring) -> SpringParameters { policy.spring(token) }
    public func duration(_ token: MotionFade) -> TimeInterval { policy.duration(token) }
    public func duration(_ token: MotionSpring) -> TimeInterval { policy.duration(token) }
    /// Seconds that stand in for `token` in `window`; 0 when movement does not animate there (``animatesMovement(in:)``).
    public func duration(_ token: MotionSpring, in window: NSWindow?) -> TimeInterval { policy(in: window).duration(token) }
    public func period(_ loop: MotionLoop) -> TimeInterval? { policy.period(loop) }
}
