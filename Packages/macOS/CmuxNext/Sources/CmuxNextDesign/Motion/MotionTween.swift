import CCmuxMotionFFI
public import CoreGraphics
public import Foundation
public import CmuxNextDesignTokens

/// Tween tokens: Chrome's tab strip motion (design-tokens.json
/// `motion.tweens`, 200 ms 1-(1-t)^2). A tweened value goes from where it is
/// on screen to its target over the token's duration; a new target restarts
/// the duration from the current value with no velocity, and setting the
/// target it already has does not restart it. Durations and the curve come
/// from cmux-motion through the app FFI; no copy lives here. Cases are in
/// cmux-motion's `MotionTween::ALL` order (the C ABI token number).
public nonisolated enum MotionTween: UInt8, Sendable, CaseIterable {
    /// A new tab opening at its slot, its neighbours and the + making room (`ui.animations.newTab`).
    case tabOpen = 0
    /// A closing tab shrinking with its left edge pinned, the others closing the gap (`ui.animations.newTab`).
    case tabClose = 1
    /// A reorder, a crowding change, a dragged tab settling on release. A gesture: no kind switch.
    case tabMove = 2

    /// Seconds and curve at speed `fast` from the spec.
    public var base: (duration: TimeInterval, curve: UInt8) {
        var out = CmuxMotionTween(duration: 0, curve: 0)
        return cmux_motion_tween_base(rawValue, &out) ? (out.duration, out.curve) : (0, 0)
    }
}

nonisolated extension MotionPolicy {
    /// This policy for the motion C ABI.
    var ffi: CmuxMotionPolicy {
        // The master switch or this policy's category off is speed "off" for the C ABI.
        let speedIndex: UInt8
        if !categoryAnimates {
            speedIndex = 2
        } else {
            speedIndex = switch speed {
            case .fast: 0
            case .normal: 1
            case .off: 2
            }
        }
        return CmuxMotionPolicy(speed: speedIndex, reduce_motion: reduceMotion || liveResize, bounce: bounce == .subtle ? 1 : 0,
                                pane_animations: false, new_tab: enabledKinds.contains(.newTab),
                                new_workspace: enabledKinds.contains(.newWorkspace))
    }

    /// Seconds of `token`; 0 applies at once: speed off, Reduce Motion (Chrome's strip is 0 ms
    /// under it), a live resize, or tabOpen/tabClose with `ui.animations.newTab` off.
    public func duration(_ token: MotionTween) -> TimeInterval {
        cmux_motion_tween_seconds(token.rawValue, ffi)
    }
}

extension MotionGate {
    /// Seconds of tween `token` in this gate's category; 0 applies at once.
    public func duration(_ token: MotionTween) -> TimeInterval { policy.duration(token) }
}

/// One scalar on a tween (cmux-motion `TweenValue`, stepped through the app
/// FFI). Pure: the caller passes the duration (`Motion.tabs.duration(token)`).
public nonisolated struct TweenValue: Equatable, Sendable {
    public private(set) var value: CGFloat
    public private(set) var target: CGFloat
    private var from: Double
    private var elapsed: Double = 0
    private var duration: Double = 0
    /// The token of the running (or last) tween: its curve, and what the
    /// owner gates on.
    public var token: MotionTween

    public init(_ value: CGFloat, token: MotionTween = .tabMove) {
        self.value = value
        self.target = value
        self.from = Double(value)
        self.token = token
    }

    public var isSettled: Bool { value == target }

    private var state: CmuxMotionTweenState {
        CmuxMotionTweenState(value: Double(value), from: from, target: Double(target), elapsed: elapsed, duration: duration)
    }

    private mutating func apply(_ s: CmuxMotionTweenState) {
        (value, from, target, elapsed, duration) = (CGFloat(s.value), s.from, CGFloat(s.target), s.elapsed, s.duration)
    }

    /// Points at `target` over `duration` seconds from the current value. The same target changes
    /// nothing and returns false; 0 seconds applies it at once.
    @discardableResult
    public mutating func retarget(_ target: CGFloat, duration: TimeInterval, token: MotionTween? = nil) -> Bool {
        var s = state
        guard cmux_motion_tween_retarget(&s, Double(target), duration) else { return false }
        apply(s)
        if let token { self.token = token }
        return true
    }

    /// Advances `dt` seconds on the token's curve. True while still moving.
    public mutating func step(_ dt: Double) -> Bool {
        guard !isSettled else { return false }
        var s = state
        let moving = cmux_motion_tween_step(&s, dt, token.base.curve)
        apply(s)
        return moving
    }

    /// Jumps to the target and stops.
    public mutating func snap() {
        (value, from, elapsed, duration) = (target, Double(target), 0, 0)
    }

    public mutating func snap(to target: CGFloat) {
        self.target = target
        snap()
    }
}

/// The tab strip geometry of the Chrome motion (design-tokens.json
/// `motion.tabStrip`, through the app FFI).
public nonisolated struct MotionTabStrip: Equatable, Sendable {
    public var maxWidth: CGFloat
    /// A new tab starts this wide at the previous tab's right edge minus this.
    public var openStartWidth: CGFloat
    /// A closing tab ends this wide, its left edge pinned to the previous tab's right edge minus this.
    public var closeEndWidth: CGFloat
    public var minActiveWidth: CGFloat
    public var minInactiveWidth: CGFloat
    public var pinnedWidth: CGFloat
    /// Pointer travel since the last reorder that reorders again, at `maxWidth`.
    public var reorderThreshold: CGFloat
    /// Mouse closing mode ends this far below the strip, or this far past its trailing edge ...
    public var closingModeBelowPad: CGFloat
    public var closingModeTrailingPad: CGFloat
    /// ... plus this many seconds.
    public var closingModeExitDelay: TimeInterval

    /// The spec's geometry for `comfortable` (else compact) density.
    public init(comfortable: Bool) {
        var g = CmuxMotionTabStripGeometry()
        _ = cmux_motion_tab_strip_geometry(comfortable ? 1 : 0, &g)
        maxWidth = g.max_width
        openStartWidth = g.open_start_width
        closeEndWidth = g.close_end_width
        minActiveWidth = g.min_active_width
        minInactiveWidth = g.min_inactive_width
        pinnedWidth = g.pinned_width
        reorderThreshold = g.reorder_threshold
        closingModeBelowPad = g.closing_mode_below_pad
        closingModeTrailingPad = g.closing_mode_trailing_pad
        closingModeExitDelay = g.closing_mode_exit_delay
    }

    /// Every length multiplied by `scale` (the UI scale); the delay and `maxWidth` (the threshold's
    /// reference) stay.
    public func scaled(by scale: CGFloat) -> MotionTabStrip {
        var g = self
        g.openStartWidth *= scale
        g.closeEndWidth *= scale
        g.minActiveWidth *= scale
        g.minInactiveWidth *= scale
        g.pinnedWidth *= scale
        g.closingModeBelowPad *= scale
        g.closingModeTrailingPad *= scale
        return g
    }

    /// The reorder threshold for a tab `width` wide (16 x width / 200).
    public func reorderThreshold(forTabWidth width: CGFloat) -> CGFloat {
        maxWidth > 0 ? reorderThreshold * width / maxWidth : 0
    }
}
