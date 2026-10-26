/// Moves a pointer stream to a frame's time: a port of Chromium's `LinearResampling`
/// (`ui/base/prediction/linear_resampling.cc`, constants from there and from `ui/base/prediction/input_predictor.h`).
///
/// The sample time is the frame time plus ``resampleLatency`` (-5 ms), so a frame mostly interpolates between the
/// two newest samples instead of guessing ahead. Extrapolation past the newest sample is capped at
/// min(``maxPrediction``, last dt / 2). There is no result until two samples ``minDelta`` (2 ms) or more apart
/// have arrived, and a gap over ``maxTimeDelta`` (20 ms) starts a new trajectory.
///
/// One cmux addition, not in Chromium: when the newest segment turns against the one before it (negative dot
/// product), the result never goes past the newest sample, so a reversal does not overshoot on screen.
///
/// Frame-ahead prediction is Chromium's `kResamplingScrollEventsExperimentalPrediction` frames-based mode
/// (`ui/base/ui_base_features.cc`, disabled by default): ``frameAhead`` frames are added to the sample time and
/// the max-prediction cap is lifted. The default is 0, Chromium's default behavior.
///
/// Times are seconds since boot (the clock of ``PointerSample/timestamp``). Visual use only: drop targets, snaps
/// and flings read real samples (p04-input.md section 3 (D)).
public struct InputResampler: Hashable, Sendable {
    /// `kResampleLatency`: the sample time's offset from the frame time.
    public static let resampleLatency: Double = -0.005
    /// `kResampleMaxPrediction`: the longest extrapolation past the newest sample.
    public static let maxPrediction: Double = 0.008
    /// `kResampleMinDelta`: the shortest gap between the two newest samples that gives a result.
    public static let minDelta: Double = 0.002
    /// `InputPredictor::kMaxTimeDelta`: a longer gap between samples starts a new trajectory.
    public static let maxTimeDelta: Double = 0.020
    /// `InputPredictor::kTimeInterval`: the sample interval reported before two samples have arrived.
    public static let defaultTimeInterval: Double = 0.008

    /// Frames of prediction ahead of the frame time; 0 (the default) is Chromium's default behavior.
    public var frameAhead: Double

    private var newest: PointerSample?
    private var previous: PointerSample?
    /// The displacement into ``previous``, kept only for the direction-change rule (cmux addition).
    private var previousDelta: InputPoint?

    public init(frameAhead: Double = 0) {
        self.frameAhead = frameAhead
    }

    /// Forgets every sample (`LinearResampling::Reset`): call at the end of a drag or a scroll.
    public mutating func reset() {
        newest = nil
        previous = nil
        previousDelta = nil
    }

    /// Adds the next sample (`LinearResampling::Update`); a gap over ``maxTimeDelta`` resets first.
    public mutating func update(_ sample: PointerSample) {
        if let newest, sample.timestamp - newest.timestamp > Self.maxTimeDelta {
            reset()
        }
        if let newest, let previous {
            previousDelta = InputPoint(x: newest.location.x - previous.location.x, y: newest.location.y - previous.location.y)
        }
        previous = newest
        newest = sample
    }

    /// Whether ``resample(frameTime:frameInterval:)`` gives a result (`LinearResampling::HasPrediction`).
    public var hasPrediction: Bool {
        guard let newest, let previous else { return false }
        return newest.timestamp - previous.timestamp >= Self.minDelta
    }

    /// The gap between the two newest samples, or ``defaultTimeInterval`` before there are two
    /// (`LinearResampling::TimeInterval`).
    public var timeInterval: Double {
        guard let newest, let previous else { return Self.defaultTimeInterval }
        return newest.timestamp - previous.timestamp
    }

    /// The pointer at the frame's sample time (`LinearResampling::GeneratePrediction`), or nil when there is no
    /// prediction yet. `frameInterval` is the display's refresh interval in seconds; only frame-ahead mode reads it.
    public func resample(frameTime: Double, frameInterval: Double) -> PointerSample? {
        guard hasPrediction, let newest, let previous else { return nil }
        let dt = newest.timestamp - previous.timestamp
        var sampleTime: Double
        if frameAhead > 0 {
            sampleTime = frameTime + frameAhead * frameInterval + Self.resampleLatency
        } else {
            sampleTime = min(frameTime + Self.resampleLatency, newest.timestamp + min(Self.maxPrediction, dt / 2))
        }
        if reversesDirection(newest: newest, previous: previous) {
            sampleTime = min(sampleTime, newest.timestamp)
        }
        let alpha = (sampleTime - newest.timestamp) / dt
        let location = InputPoint(
            x: newest.location.x + (newest.location.x - previous.location.x) * alpha,
            y: newest.location.y + (newest.location.y - previous.location.y) * alpha
        )
        return PointerSample(location: location, timestamp: sampleTime)
    }

    /// cmux addition: the newest segment points against the one before it.
    private func reversesDirection(newest: PointerSample, previous: PointerSample) -> Bool {
        guard let previousDelta else { return false }
        let dx = newest.location.x - previous.location.x
        let dy = newest.location.y - previous.location.y
        return dx * previousDelta.x + dy * previousDelta.y < 0
    }
}
