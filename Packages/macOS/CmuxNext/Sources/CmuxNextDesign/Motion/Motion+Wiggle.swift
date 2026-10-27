public import QuartzCore

extension MotionGate {
    /// Edit mode's wiggle: a turn of `angle` radians either way about `center` (the layer's own
    /// coordinates), one back-and-forth per `wiggle` period, starting `phase` (0...1) into it so
    /// neighbors do not move in step; nil under Reduce Motion or with the sidebar's motion off (the
    /// item stays still). The person entered edit mode and the wiggle is its sign, so Energy Saver
    /// leaves it (``MotionLoop/isAmbient``). Run it through ``LoopVisibility/attach(_:key:make:)``:
    /// off while the item is hidden or its window occluded, and back with neighbors still out of step
    /// (`phase` is its `timeOffset`, on top of the shared clock's phase).
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
