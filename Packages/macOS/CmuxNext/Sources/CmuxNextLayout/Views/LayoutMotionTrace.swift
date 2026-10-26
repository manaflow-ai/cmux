import CmuxNextSignposts
import CmuxNextTrace

/// One window's layout motion trace points (one ``LayoutRootView``): a ``SignpostName/motionFrame`` slice per
/// display tick, and a ``SignpostName/motionRun`` async slice from the structural change that starts the springs
/// (a split, a close, a screen switch) to the frame they rest in.
///
/// Chrome traces the same two levels: a slice per main frame (`ProxyMain::BeginMainFrame`,
/// cc/trees/proxy_main.cc) and a nestable async slice per animation sequence keyed by its tracker
/// (cc/metrics/frame_sequence_tracker.cc), with a pointer-local id (`TRACE_ID_LOCAL(this)`,
/// base/trace_event/trace_id_helper.h). Numbers only, into the Release trace ring under the `motion` category:
/// with the category off a tick costs one relaxed load, and no clock read or pane count.
final class LayoutMotionTrace {
    private let trace: TraceRuntime
    /// Times each recorded frame for the run's longest frame (the ring stamps its own records).
    private let clock: TraceClock
    private var run: Run?
    /// Runs this window opened: the top 16 bits of the next run's async id.
    private var runCount: UInt64 = 0

    /// The open run's async id and what its frames measured so far.
    private struct Run {
        let id: UInt64
        var frames: UInt32 = 0
        var longestFrameNanos: UInt64 = 0
    }

    /// - Parameters:
    ///   - trace: The ring the records go to (the app's: ``TraceRuntime/shared``; tests pass their own).
    ///   - clock: The clock a frame's length is read from (tests pass one that advances a fixed step per read).
    init(trace: TraceRuntime = .shared, clock: TraceClock = TraceClock()) {
        self.trace = trace
        self.clock = clock
    }

    /// Whether a `motion.run` is open (its begin was recorded and its springs have not rested).
    var isRunOpen: Bool { run != nil }

    /// A structural change started springs that step on the CPU: opens a run unless one is open (a change
    /// during a motion retargets the same springs, so the run goes on until they rest). Records nothing while
    /// the `motion` category is off.
    func beginRun() {
        guard run == nil else { return }
        runCount &+= 1
        let address = UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        let id = address | (runCount & 0xFFFF) << 48
        guard trace.asyncBegin(.motionRun, id: id) else { return }
        run = Run(id: id)
    }

    /// One display tick of the window: `body` steps its springs and presents the frame inside a `motion.frame`
    /// slice whose begin holds `movedPanes` (read only while the category is on) and the tick's `dt` in us. The
    /// open run counts the frame and keeps the longest.
    ///
    /// - Returns: What `body` returns (whether the window needs another tick).
    func frame(dt: Double, movedPanes: @autoclosure () -> Int, _ body: () -> Bool) -> Bool {
        let traced = trace.isEnabled(categoryBit: Self.motion.traceBit)
            && trace.begin(.motionFrame, arg0: UInt64(clamping: movedPanes()), arg1: Self.micros(seconds: dt))
        guard traced || run != nil else { return body() }
        let start = clock.nowNanos()
        let result = body()
        let end = clock.nowNanos()
        if traced {
            trace.writeEnd(name: SignpostName.motionFrame.rawValue, categoryBit: Self.motion.traceBit, phase: .end)
        }
        if var open = run {
            open.frames = open.frames == .max ? .max : open.frames + 1
            open.longestFrameNanos = max(open.longestFrameNanos, end >= start ? end - start : 0)
            run = open
        }
        return result
    }

    /// The springs rested, or the window stopped stepping them (Reduce Motion landed them, the root parked or
    /// went away): ends the open run with its frames and longest frame (``SignpostName/motionRun``). Its begin
    /// was recorded, so its end is too, whatever the category flags are now.
    func endRun() {
        guard let open = run else { return }
        run = nil
        trace.writeEnd(name: SignpostName.motionRun.rawValue, categoryBit: Self.motion.traceBit, phase: .asyncEnd,
                       flags: .asyncID, arg0: Self.runResult(frames: open.frames, longestFrameNanos: open.longestFrameNanos),
                       arg1: open.id)
    }

    private static let motion = SignpostName.motionFrame.traceCategory

    /// `seconds` in whole microseconds, 0 for a negative or NaN time, saturated at `UInt32.max`.
    static func micros(seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(min((seconds * 1_000_000).rounded(), Double(UInt32.max)))
    }

    /// A run's end `arg0`: the frames in bits 0-31 and the longest frame in us (saturated) in bits 32-63.
    static func runResult(frames: UInt32, longestFrameNanos: UInt64) -> UInt64 {
        UInt64(frames) | UInt64(min(longestFrameNanos / 1_000, UInt64(UInt32.max))) << 32
    }
}
