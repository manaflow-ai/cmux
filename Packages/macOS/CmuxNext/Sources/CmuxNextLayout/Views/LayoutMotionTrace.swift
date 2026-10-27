import CmuxNextSignposts
import CmuxNextWakeups

/// One window's layout motion signposts (one ``LayoutRootView``): a ``SignpostName/motionFrame`` interval per
/// display tick, and a ``SignpostName/motionRun`` interval from the structural change that starts the motion (a
/// split, a close, a screen switch; on the CPU step or the render server) to the moment it rests.
///
/// Chrome traces the same two levels: a slice per main frame (`ProxyMain::BeginMainFrame`,
/// cc/trees/proxy_main.cc) and an async slice per animation sequence (cc/metrics/frame_sequence_tracker.cc), which
/// also tracks compositor-driven animations. Both go through the injected ``Signposter``, so each is one
/// `OSSignposter` interval (Instruments), the MetricKit mirror's for `motion.run`, and a trace ring slice while the
/// `motion` category is on. A run is also its window's motion frame sequence (``FrameScheduler/beginMotionSequence()``,
/// Chrome's `FrameSequenceTracker` of the animation), so `smoothness.dropped_pct.motion` counts exactly the run.
final class LayoutMotionTrace {
    private let signposter: Signposter
    private var run: Run?

    /// The open run's interval and what its CPU frames measured so far.
    private struct Run {
        let interval: SignpostInterval
        /// The scheduler of the window the run began in, whose motion sequence it holds open.
        weak var scheduler: FrameScheduler?
        var frames: UInt32 = 0
        var longestFrameNanos: UInt64 = 0
    }

    /// - Parameter signposter: The `motion` category's signposter (the app's: ``Signposter/motion``; tests pass
    ///   one on their own trace runtime, MetricKit mirror and clock).
    init(signposter: Signposter) {
        self.signposter = signposter
    }

    /// The open `motion.run`, nil at rest.
    var openRun: SignpostInterval? { run?.interval }

    /// A structural change started motion, on the CPU step or the render server: opens a run unless one is open
    /// (a change during a motion retargets the same springs, so the run goes on until they rest). `scheduler`, the
    /// window's (nil without one), counts the run's frames as its motion sequence.
    func beginRun(on scheduler: FrameScheduler?) {
        guard run == nil else { return }
        scheduler?.beginMotionSequence()
        run = Run(interval: signposter.begin(.motionRun), scheduler: scheduler)
    }

    /// One display tick of the window: `body` steps its springs and presents the frame inside a `motion.frame`
    /// interval that holds `movedPanes` and the tick's `dt` in us. The open run counts the frame and keeps the
    /// longest. While nothing takes `motion` signposts and no run is open, the tick only runs `body`.
    ///
    /// - Returns: What `body` returns (whether the window needs another tick).
    func frame(dt: Double, movedPanes: () -> Int, _ body: () -> Bool) -> Bool { // perf-hot: 4ms motion-frame
        guard run != nil || signposter.isEnabled else { return body() }
        let interval = signposter.beginMotionFrame(movedPanes: UInt64(clamping: movedPanes()), dtMicros: Self.micros(seconds: dt))
        let result = body()
        let end = signposter.nowNanos()
        signposter.end(.motionFrame, interval)
        if var open = run {
            open.frames = open.frames == .max ? .max : open.frames + 1
            let length = end >= interval.beginUptimeNanos ? end - interval.beginUptimeNanos : 0
            open.longestFrameNanos = max(open.longestFrameNanos, length)
            run = open
        }
        return result
    }

    /// The motion rested, or the window stopped it (Reduce Motion landed it, the root parked or went away): ends
    /// the open run with its CPU frames and the longest of them.
    func endRun() {
        guard let open = run else { return }
        run = nil
        open.scheduler?.endMotionSequence()
        signposter.endMotionRun(open.interval, frames: open.frames,
                                longestFrameMicros: UInt32(min(open.longestFrameNanos / 1_000, UInt64(UInt32.max))))
    }

    /// `seconds` in whole microseconds, 0 for a negative or NaN time, saturated at `UInt32.max`.
    static func micros(seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(min((seconds * 1_000_000).rounded(), Double(UInt32.max)))
    }
}
