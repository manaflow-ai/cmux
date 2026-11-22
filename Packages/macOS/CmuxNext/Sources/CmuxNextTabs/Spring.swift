public import CmuxNextDesign
public import CoreGraphics
public import Foundation

/// A damped spring driven frame by frame by the strip's display link, tuned
/// by a `Motion` token that is resolved on every step (so a speed change
/// applies mid-flight). Retargeting keeps value and velocity, so an
/// interrupted animation continues from what is on screen.
public struct Spring: Equatable, Sendable {
    /// What the spring animates (the cmux-motion SpringKind rule). A size
    /// (width, opacity) reaching 0 is something disappearing; a position
    /// (a tab's x, the strip scroll) reaching 0 is an ordinary move.
    public enum Kind: Sendable { case size, position }

    public var value: CGFloat
    public var velocity: CGFloat = 0
    public var target: CGFloat
    /// The spring for moves. A size spring moving to 0 (close, collapse,
    /// fade out) uses `.disappear`, which is faster; a position spring
    /// always uses this token.
    public var token: MotionSpring
    public let kind: Kind
    /// Settle distance. Geometry snaps to half points at 2x, so 0.25 pt of
    /// remaining travel is invisible; opacity uses a finer value.
    public var epsilon: CGFloat
    /// Pointer sample for `follow(_:at:)`.
    private var lastSample: (value: CGFloat, time: TimeInterval)?

    public init(value: CGFloat, token: MotionSpring = .move, kind: Kind = .size, epsilon: CGFloat = 0.25) {
        self.value = value
        self.target = value
        self.token = token
        self.kind = kind
        self.epsilon = epsilon
    }

    public static func == (lhs: Spring, rhs: Spring) -> Bool {
        lhs.value == rhs.value && lhs.velocity == rhs.velocity && lhs.target == rhs.target && lhs.token == rhs.token && lhs.kind == rhs.kind
            && lhs.epsilon == rhs.epsilon
    }

    /// The token this step uses.
    public var activeToken: MotionSpring {
        kind == .size && target <= 0.001 && value > target ? .disappear : token
    }

    public var isSettled: Bool {
        abs(target - value) < epsilon && abs(velocity) < epsilon * 8
    }

    public mutating func snap() {
        value = target
        velocity = 0
        lastSample = nil
    }

    public mutating func snap(to target: CGFloat) {
        self.target = target
        snap()
    }

    /// Direct manipulation: the value is exactly `value` (no lag), and the
    /// velocity is estimated from pointer samples so a release carries it.
    public mutating func follow(_ newValue: CGFloat, at time: TimeInterval) {
        if let last = lastSample, time > last.time {
            let instant = (newValue - last.value) / CGFloat(time - last.time)
            // Light smoothing: pointer events jitter at high rates.
            velocity = velocity * 0.4 + instant * 0.6
        }
        lastSample = (newValue, time)
        value = newValue
        target = newValue
    }

    /// Ends direct manipulation at `time`: the next steps settle with the
    /// `settle` spring from the pointer's velocity, or from rest when the
    /// pointer had stopped (no sample in the last 50 ms).
    public mutating func release(at time: TimeInterval) {
        if let last = lastSample, time - last.time > 0.05 { velocity = 0 }
        lastSample = nil
        token = .settle
    }

    /// Advances by `dt` seconds with the token's spring.
    public mutating func step(_ dt: CGFloat) {
        step(dt, parameters: Motion.spring(activeToken))
    }

    /// Advances by `dt` seconds with fixed substeps (stable at any frame rate).
    public mutating func step(_ dt: CGFloat, parameters: SpringParameters) {
        lastSample = nil
        guard !isSettled else {
            settle()
            return
        }
        var state = SpringValue(value)
        state.velocity = velocity
        state.target = target
        state.step(Double(dt), parameters: parameters)
        value = state.value
        velocity = state.velocity
        if isSettled { settle() }
    }

    private mutating func settle() {
        snap()
        // A release spring is for that release only; later reflows move normally.
        if token == .settle { token = .move }
    }
}
