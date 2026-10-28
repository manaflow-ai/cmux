public import QuartzCore

/// A layer's own clock (`CAMediaTiming` `speed`, `beginTime`, `timeOffset`): the local time it shows
/// at a parent time `t` is `(t - beginTime) * speed + timeOffset`. Every animation on the layer and its
/// sublayers runs on that time, on the render server, so changing a window's root time base slows,
/// pauses or steps every Core Animation animation in the window at once, gated or not, already running
/// or not yet added (the Motion Inspector's slow motion, ``MotionInspector``).
///
/// Pure value math, so the rules are tested without a window: a retime keeps the local time where it
/// is (no animation jumps), a step moves it by whole seconds of animation time.
public nonisolated struct MotionTimebase: Sendable, Equatable {
    public var speed: Float
    public var beginTime: CFTimeInterval
    public var timeOffset: CFTimeInterval

    /// Real time: a layer that has not been retimed.
    public static let identity = MotionTimebase(speed: 1, beginTime: 0, timeOffset: 0)

    public init(speed: Float, beginTime: CFTimeInterval, timeOffset: CFTimeInterval) {
        self.speed = speed
        self.beginTime = beginTime
        self.timeOffset = timeOffset
    }

    /// `layer`'s time base now.
    @MainActor public init(of layer: CALayer) {
        self.init(speed: layer.speed, beginTime: layer.beginTime, timeOffset: layer.timeOffset)
    }

    /// The local time at parent time `parent`.
    public func localTime(atParent parent: CFTimeInterval) -> CFTimeInterval {
        (parent - beginTime) * Double(speed) + timeOffset
    }

    /// The same local time at `parent`, running at `rate` local seconds per parent second from there
    /// (0 holds it still).
    public func retimed(rate: Double, atParent parent: CFTimeInterval) -> MotionTimebase {
        MotionTimebase(speed: Float(rate), beginTime: parent, timeOffset: localTime(atParent: parent))
    }

    /// The local time moved by `seconds` (negative steps back), its rate unchanged.
    public func stepped(by seconds: CFTimeInterval) -> MotionTimebase {
        var stepped = self
        stepped.timeOffset += seconds
        return stepped
    }

    /// Writes the time base to `layer` with no implicit animation.
    @MainActor public func apply(to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = speed
        layer.beginTime = beginTime
        layer.timeOffset = timeOffset
        CATransaction.commit()
    }
}
