/// One drag delivery's two points (p04-input.md section 3 (D)).
///
/// - ``realPoint``: the newest pointer sample the OS sent. Every decision reads it: snaps, drop
///   zones, hit tests, the release velocity and the release itself.
/// - ``visualPoint``: where the drag is drawn this frame, the pointer resampled at the frame's time
///   (``DragResampler``), or ``realPoint`` when nothing was resampled.
public struct PointerDragPoints: Hashable, Sendable {
    public var realPoint: InputPoint
    /// The OS event time of ``realPoint`` (seconds since boot).
    public var realTime: Double
    public var visualPoint: InputPoint

    public init(realPoint: InputPoint, realTime: Double, visualPoint: InputPoint) {
        self.realPoint = realPoint
        self.realTime = realTime
        self.visualPoint = visualPoint
    }

    /// The real sample drawn where it is: no resampling.
    public init(real sample: PointerSample) {
        self.init(realPoint: sample.location, realTime: sample.timestamp, visualPoint: sample.location)
    }
}

/// Resamples a drag at its frame's time for what the drag draws, as Chromium resamples rAF-aligned
/// pointer input with ``InputResampler`` (`LinearResampling`) in `MainThreadEventQueue::HandleEventResampling`
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`) and scrolls in
/// `ScrollPredictor::ResampleScrollEvents` (`third_party/blink/renderer/platform/widget/input/scroll_predictor.cc`).
///
/// Every real sample of a delivery feeds the resampler, so a frame's delivery interpolates between the
/// frame's own points. A delivery that goes out at once (cmux's leading edge, a flush before a button) is
/// resampled at its newest event's time, so the drawn point keeps the same lag behind the pointer as at a
/// frame. The resample time never goes back within a drag: a frame tick whose vsync time is older than a
/// leading edge that ran before it (main ran the tick late) resamples at the leading edge's time, so the
/// drawn point never steps back against the drag.
///
/// ```swift
/// var resampler = DragResampler(frameAheadMs: 0)
/// let points = resampler.points(for: input, at: frame)
/// divider.draw(at: points.visualPoint)
/// snap.decide(at: points.realPoint)
/// ```
public struct DragResampler: Hashable, Sendable {
    /// Debug frame-ahead prediction in milliseconds (`input.resampleFrameAheadMs`, ``InputResampler/frameAheadMs``;
    /// 0, the default, is Chromium's default: interpolate 5 ms behind the frame).
    public let frameAheadMs: Double
    private var resampler: InputResampler
    /// The latest time this drag was resampled at; the next resample is never earlier.
    private var lastResampleTime = -Double.infinity

    public init(frameAheadMs: Double = 0) {
        self.frameAheadMs = max(0, frameAheadMs)
        resampler = InputResampler(frameAheadMs: self.frameAheadMs)
    }

    /// Forgets the drag's samples (a new drag, or its end): `LinearResampling::Reset`.
    public mutating func reset() {
        resampler.reset()
        lastResampleTime = -Double.infinity
    }

    /// Feeds `input`'s real samples and gives its real and drawn points for `frame`.
    public mutating func points(for input: PointerCoalescedInput, at frame: PointerFrameTime) -> PointerDragPoints { // perf-hot: 2us resize-drag (each resampled drag delivery)
        let latest = PointerSample(location: input.latest.location, timestamp: input.latest.timestamp)
        if input.samples.isEmpty {
            resampler.update(latest)
        } else {
            for sample in input.samples { resampler.update(sample) }
        }
        guard let visual = visualPoint(at: frame.time) else { return PointerDragPoints(real: latest) }
        return PointerDragPoints(realPoint: latest.location, realTime: latest.timestamp, visualPoint: visual)
    }

    /// The pointer resampled at `time`, no earlier than the drag's previous resample time; nil before
    /// there are two samples far enough apart.
    private mutating func visualPoint(at time: Double) -> InputPoint? {
        let time = max(time, lastResampleTime)
        lastResampleTime = time
        return resampler.resample(frameTime: time)?.location
    }
}
