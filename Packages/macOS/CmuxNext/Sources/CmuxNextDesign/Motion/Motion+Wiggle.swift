public import QuartzCore

extension MotionGate {
    /// Edit mode's wiggle: a turn of `angle` radians either way about `center` (the layer's own
    /// coordinates), one back-and-forth per `wiggle` period, starting `phase` (0...1) into it so
    /// neighbors do not move in step; nil when loops are off (the item stays still).
    public func wiggleAnimation(center: CGPoint, angle: CGFloat = 0.022, phase: Double = 0) -> CAAnimation? {
        guard let period = period(.wiggle) else { return nil }
        func turn(_ angle: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DRotate(transform, angle, 0, 0, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(transform, -center.x, -center.y, 0))
        }
        let wiggle = CAKeyframeAnimation(keyPath: "transform")
        wiggle.values = [turn(-angle), turn(angle), turn(-angle)]
        wiggle.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        wiggle.duration = period
        wiggle.timeOffset = period * min(max(phase, 0), 1)
        wiggle.repeatCount = .infinity
        wiggle.isRemovedOnCompletion = false
        return wiggle
    }
}
