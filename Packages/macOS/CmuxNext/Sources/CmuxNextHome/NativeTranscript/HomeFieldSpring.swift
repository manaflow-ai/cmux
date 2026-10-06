import AppKit

/// Moves the Liquid Glass field along the shared field spring. AppKit lays
/// the glass out at the view's model size, so the view's frame is animated
/// (AppKit applies it each frame) with the render core's keyframes
/// (`HomeController.fieldKeyframes`), the curve that moves the rows. The
/// timing is the render core's field token (CmuxHomeRender `HomeMotion`),
/// not a CmuxNextDesign Motion token: rows and field must share one curve.
enum HomeFieldSpring {
    static func animate(_ view: NSView, to new: CGRect, keyframes: (duration: Double, keyTimes: [Double], frames: [CGRect])) {
        let times = keyframes.keyTimes.map { NSNumber(value: $0) }
        // motion-allow: keyframes sampled from the shared render-core field spring (HomeMotion token)
        let size = CAKeyframeAnimation()
        size.values = keyframes.frames.map { NSValue(size: $0.size) }
        size.keyTimes = times
        size.duration = keyframes.duration
        // motion-allow: same shared field spring as `size`
        let origin = CAKeyframeAnimation()
        origin.values = keyframes.frames.map { NSValue(point: $0.origin) }
        origin.keyTimes = times
        origin.duration = keyframes.duration
        view.animations = ["frameSize": size, "frameOrigin": origin]
        // motion-allow: AppKit applies the view keyframes above; duration is the shared spring's
        NSAnimationContext.runAnimationGroup { context in
            context.duration = keyframes.duration
            view.animator().frame = new
        }
    }
}
