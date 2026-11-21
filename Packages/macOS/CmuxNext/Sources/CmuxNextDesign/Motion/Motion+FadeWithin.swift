public import QuartzCore
public import CmuxNextDesignTokens

extension MotionGate {
    /// Sets `layer.keyPath` to `value` on the fade `token`, in at most `limit` seconds: a fade that must end with a
    /// motion that began in the same frame (the dim of an unzoom and the move of its pane). The time has one source,
    /// the motion's own: where the motion is longer than the token's fade, the fade is the token's.
    /// Returns the added animation, or nil.
    @discardableResult
    public func set(_ layer: CALayer, _ keyPath: String, to value: Any, fade token: MotionFade, atMost limit: TimeInterval,
                    from: Any? = nil) -> CAAnimation? {
        set(layer, keyPath, to: value, duration: min(duration(token), max(0, limit)), from: from)
    }

    /// Takes `layer.keyPath` from `start` to `value` on the fade `token`, in at most `limit` seconds (nil: the token's
    /// time), for a layer that leaves when the fade is over (the dim of an unzoom). The layer's own value stays
    /// `start`, and the animation holds `value` from its end until the layer leaves or a newer set replaces it. So a
    /// layer whose animation does not run shows `start` for that time, never `value` before its time is over.
    /// With no time (the speed is off) the layer's own value is `value` at once. Returns the added animation, or nil.
    @discardableResult
    public func fadeAway(_ layer: CALayer, _ keyPath: String, from start: Any, to value: Any, fade token: MotionFade,
                         atMost limit: TimeInterval? = nil) -> CAAnimation? {
        let time = limit.map { min(duration(token), max(0, $0)) } ?? duration(token)
        // One commit for the model value and its animation (see `Motion.setModel`).
        CATransaction.begin()
        defer { CATransaction.commit() }
        guard time > 0 else {
            Motion.setModel(layer, keyPath, value)
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        Motion.setModel(layer, keyPath, start)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = time
        animation.timingFunction = fadeCurve
        animation.fromValue = start
        animation.toValue = value
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).held")
        return animation
    }
}
