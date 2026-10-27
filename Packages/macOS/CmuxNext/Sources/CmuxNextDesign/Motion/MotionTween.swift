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
