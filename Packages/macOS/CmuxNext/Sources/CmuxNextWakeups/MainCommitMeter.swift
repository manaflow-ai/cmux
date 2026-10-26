/// The main thread's commit estimate: the 95th percentile of the last 32 frames' render passes
/// (AppKit's layout and display plus the Core Animation commit, the main run loop's before-waiting
/// phase that ``RenderPassMeter`` times; the `ca.commit` span of `debug.motion` is its commit part).
///
/// ``MainFrameBudget`` ends a frame's budgeted work this long before the frame's target time, so
/// the commit of what the work changed reaches the render server before the vsync it is due for.
/// This is Chromium's deadline estimate: `cc/scheduler/compositor_timing_history.cc` keeps a rolling
/// history of main-frame durations and schedules against a high percentile of it, and
/// `cc/scheduler/scheduler.cc` sets the main frame's deadline from that estimate and
/// `BeginFrameArgs::deadline` (`components/viz/common/frame_sinks/begin_frame_args.h`).
///
/// One sample per frame: the longest pass since the frame's window opened (a frame has one pass
/// that commits and may have empty ones around it).
struct MainCommitMeter {
    /// Frames the estimate looks back over.
    static let capacity = 32

    /// The ring of samples, in nanoseconds (filled up to ``capacity``, then overwritten oldest first).
    private var samples: [UInt64] = []
    private var next = 0
    /// Scratch storage the percentile sorts in, kept between frames so a frame allocates nothing.
    private var sorted: [UInt64] = []
    private var cached: UInt64?

    init() {
        samples.reserveCapacity(Self.capacity)
        sorted.reserveCapacity(Self.capacity)
    }

    /// Whether any frame was measured yet.
    var hasHistory: Bool { !samples.isEmpty }

    /// Records one frame's render pass, in nanoseconds.
    mutating func record(_ nanos: UInt64) {
        if samples.count < Self.capacity {
            samples.append(nanos)
        } else {
            samples[next] = nanos
        }
        next = (next + 1) % Self.capacity
        cached = nil
    }

    /// The 95th percentile (nearest rank) of the recorded passes; nil with no history.
    mutating func p95() -> UInt64? {
        guard !samples.isEmpty else { return nil }
        if let cached { return cached }
        sorted.removeAll(keepingCapacity: true)
        sorted.append(contentsOf: samples)
        sorted.sort()
        let rank = (sorted.count * 95 + 99) / 100
        let value = sorted[rank - 1]
        cached = value
        return value
    }
}
