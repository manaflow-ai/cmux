#if DEBUG || CMUX_BENCH_HOOKS
/// How a `debug.new_tab {action: "frame_strip"}` recording moved outside the content and the
/// tab strip (motion proofs, scripts/cmux-next/motion-proof.py, hq-1d). Each frame's `progress`
/// (0 = before, 1 = final, from its pixel shares) never goes back (`reversals`) or leaps (`jumps`
/// over `jump`, default 0.6; `maxStep`). The proof's other knobs: `gesture: "plus"` presses the
/// focused strip's + (its intent) instead of a key, `gesture: "drag_new"` drags the strip's first
/// tab while a CLI new tab lands, `content: "none"` (splits) takes no content area. Tab motion is
/// judged from the strip's own `tabs.travel` samples while `debug.motion` records
/// (``MotionTravelSummary``): a sliding cell is not monotonic in pixels.
public nonisolated struct MotionFrameProgress: Sendable, Equatable {
    public var reversals = 0
    public var jumps = 0
    public var maxStep = 0.0
    private var previous: Double?
    private var peak = 0.0
    private let jump: Double

    public init(jump: Double?) {
        self.jump = jump ?? 0.6
    }

    /// One frame, from its pixel shares outside the content and the strip that match the frame
    /// before the gesture and the final frame.
    public mutating func add(outsideBefore: Double, outsideFinal: Double) {
        let total = outsideBefore + outsideFinal
        let progress = total > 0 ? outsideBefore / total : (outsideBefore > 0 ? 1 : 0)
        if let previous {
            maxStep = max(maxStep, progress - previous)
            if progress - previous > jump, previous < 0.05 { jumps += 1 }
            if progress < peak - 0.05 { reversals += 1 }
        }
        (peak, previous) = (max(peak, progress), progress)
    }

    /// The report fields: `moving` (frames between before and final), `reversals`, `jumps`,
    /// `max_step`, and the strip's `tabs_moving_frames`, `tabs_restarts` (a second motion in one
    /// gesture) and `tabs_peak_travel`.
    public func fields(moving: Int, tabs: MotionTravelSummary) -> [String: Double] {
        ["moving": Double(moving), "reversals": Double(reversals), "jumps": Double(jumps),
         "max_step": (maxStep * 1000).rounded() / 1000, "tabs_moving_frames": Double(tabs.movingFrames),
         "tabs_restarts": Double(tabs.restarts), "tabs_peak_travel": tabs.peak.rounded()]
    }
}
#endif
