public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens

/// The motion gate of one ``MotionCategory``: the only way cmux-next code
/// animates. Every timing read and every animation helper lives here, so an
/// animation cannot start without naming its category, and each one obeys,
/// in this order: the master switch `ui.animations.enabled`, its category's
/// `ui.animations.<category>`, `ui.animationSpeed`, and the system Reduce
/// Motion setting (plans/cmux-next/motion-DESIGN.md).
///
/// Reach a gate through `Motion`:
///
/// ```swift
/// Motion.sidebar.animate(.move, in: row) { row.animator().frame = target }
/// Motion.tabs.set(layer, "opacity", to: 1, fade: .hover)
/// if let spin = Motion.indicators.spinAnimation() { layer.add(spin, forKey: "spin") }
/// ```
///
/// With its category off (or the master switch off) the gate answers like
/// speed "off": `animatesMovement`, `animatesFades` and `animatesLoops` are
/// false, every duration is 0 and every helper applies its change in one
/// frame. Code that must work with no animation at all gets that for free.
public nonisolated struct MotionGate: Sendable, Equatable {
    /// The area this gate decides for.
    public let category: MotionCategory

    /// A gate for `category`. Prefer the named gates (`Motion.sidebar`).
    public init(_ category: MotionCategory) {
        self.category = category
    }

    /// The live policy for this category: the master switch, the category
    /// switch, `ui.animationSpeed`, Reduce Motion and a live resize.
    @MainActor public var policy: MotionPolicy { Motion.basePolicy.for(category) }

    /// ``policy`` with no live resize: for values a page or a cache keeps after a drag ends.
    @MainActor public var policyIgnoringLiveResize: MotionPolicy {
        var policy = self.policy
        policy.liveResize = false
        return policy
    }

    /// The category is on and the master switch is on (speed not "off").
    @MainActor public var isEnabled: Bool { policy.categoryAnimates }
}

// Forwarders to the category-free helpers, so gate methods read like the
// static ones they replaced.
extension MotionGate {
    /// See ``Motion/canAnimate(in:)``.
    @MainActor public func canAnimate(in view: NSView?) -> Bool { Motion.canAnimate(in: view) }
    /// See ``Motion/animator(_:in:)``.
    @MainActor public func animator(_ constraint: NSLayoutConstraint, in view: NSView?) -> NSLayoutConstraint {
        Motion.animator(constraint, in: view)
    }
    /// See ``Motion/withoutAnimation(_:completion:)``.
    @MainActor public func withoutAnimation(_ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        Motion.withoutAnimation(changes, completion: completion)
    }
    /// The value on screen (``Motion/presentationValue(_:_:)``).
    @MainActor public func presentationValue(_ layer: CALayer, _ keyPath: String) -> Any? { Motion.presentationValue(layer, keyPath) }
    /// The standard ease-out curve for timed fades.
    @MainActor public var fadeCurve: CAMediaTimingFunction { Motion.fadeCurve }
    /// `ui.animationSpeed`.
    @MainActor public var speed: MotionSpeed { Motion.speed }
    @MainActor var crossfadeAction: CATransition { Motion.crossfadeAction }
    @MainActor func snap(_ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)?) {
        Motion.snap(changes, completion: completion)
    }
    @MainActor func traced(_ name: String, _ completion: (@MainActor @Sendable () -> Void)?) -> (@MainActor @Sendable () -> Void)? {
        Motion.traced(name, completion)
    }
    @MainActor func runTimed(_ duration: TimeInterval, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)?,
                             curve: CAMediaTimingFunction? = nil) {
        Motion.runTimed(duration, changes, completion: completion, curve: curve)
    }
}
