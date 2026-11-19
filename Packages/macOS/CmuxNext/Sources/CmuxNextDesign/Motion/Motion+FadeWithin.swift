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
}
