#if DEBUG || CMUX_BENCH_HOOKS
public import QuartzCore

/// How one animator's `MotionTrace` travel sample (`tabs.travel`: the points its springs have
/// left to move) ran after a time. Pixel shares cannot judge a moving tab (a cell sliding over
/// its neighbours is not monotonic in pixels); its own travel is: a spring only ever closes it.
public nonisolated struct MotionTravelSummary: Sendable, Equatable {
    /// Frames with travel left (more than half a point).
    public var movingFrames = 0
    /// Frames where the travel grew after it had started to fall: a second motion inside the
    /// gesture (or a retarget away), which one motion per gesture never has.
    public var restarts = 0
    /// The most travel any frame had left.
    public var peak = 0.0

    @MainActor public init(_ name: String, after time: CFTimeInterval) {
        var previous = 0.0, falling = false
        for sample in MotionTrace.samples where sample.name == name && sample.time >= time {
            if sample.value > 0.5 { movingFrames += 1 }
            peak = Swift.max(peak, sample.value)
            // Falling from a real motion (a few points' tail of an earlier gesture is not one).
            if peak > 4, sample.value < previous - 0.5 { falling = true }
            if falling, sample.value > previous + Swift.max(2, peak * 0.05) {
                restarts += 1
                falling = false
            }
            previous = sample.value
        }
    }
}
#endif
