import AppKit

/// Moves the Liquid Glass field along the shared field spring. AppKit lays
/// the glass out at the view's model size, so the view's frame is animated
/// (AppKit applies it each frame) with keyframes sampled from the same
/// closed form that moves the transcript rows on the render server. The
/// timing is the render core's field token (CmuxHomeRender `HomeMotion`),
/// not a CmuxNextDesign Motion token: rows and field must share one curve.
enum HomeFieldSpring {
    static let samplesPerSecond = 120.0

    static func animate(_ view: NSView, from old: CGRect, to new: CGRect,
                        curve: (duration: Double, progress: @Sendable (Double) -> Double)) {
        let n = max(2, Int((curve.duration * samplesPerSecond).rounded(.up)) + 1)
        let times = (0..<n).map { Double($0) / Double(n - 1) }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
        let progress = times.map { curve.progress($0 * curve.duration) }
        // motion-allow: keyframes sampled from the shared render-core field spring (HomeMotion token)
        let size = CAKeyframeAnimation()
        size.values = progress.map { NSValue(size: CGSize(width: lerp(old.width, new.width, $0), height: lerp(old.height, new.height, $0))) }
        size.keyTimes = times.map { NSNumber(value: $0) }
        size.duration = curve.duration
        // motion-allow: same shared field spring as `size`
        let origin = CAKeyframeAnimation()
        origin.values = progress.map { NSValue(point: CGPoint(x: lerp(old.minX, new.minX, $0), y: lerp(old.minY, new.minY, $0))) }
        origin.keyTimes = size.keyTimes
        origin.duration = curve.duration
        view.animations = ["frameSize": size, "frameOrigin": origin]
        // motion-allow: AppKit applies the view keyframes above; duration is the shared spring's
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            view.animator().frame = new
        }
    }
}
