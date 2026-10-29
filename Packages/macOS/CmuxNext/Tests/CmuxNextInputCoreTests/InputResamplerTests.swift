import CmuxNextInputCore
import Testing

/// InputResampler against Chromium's LinearResampling. The `chromium...` cases port
/// `ui/base/prediction/linear_resampling_unittest.cc` with its own sample vectors, frame times, expected values and
/// tolerance (`InputPredictorTest::kEpsilon`, `input_predictor_unittest_helpers.h`). The cases after them are cmux
/// cases: frame-ahead lifting the cap, the gap reset, reset equality, and the direction-change addition, which
/// Chromium does not have.
struct InputResamplerTests {
    /// `InputPredictorTest::kEpsilon`.
    private static let chromiumEpsilon = 0.1

    @Test func chromiumConstants() {
        #expect(InputResampler.resampleLatency == -0.005)
        #expect(InputResampler.maxPrediction == 0.008)
        #expect(InputResampler.minDelta == 0.002)
        #expect(InputResampler.maxTimeDelta == 0.020)
        #expect(InputResampler.defaultTimeInterval == 0.008)
        #expect(InputResampler().frameAheadMs == 0, "frame-ahead prediction is off by default, as in Chromium")
    }

    /// Chromium: GetResampleLatencyDefault (-5 ms with no feature on); the frame-ahead term is added to it.
    @Test func chromiumGetResampleLatencyDefault() {
        #expect(abs(InputResampler().sampleLatency - Self.ms(-5)) < 1e-12)
        #expect(abs(InputResampler(frameAheadMs: 5).sampleLatency) < 1e-12)
        #expect(abs(InputResampler(frameAheadMs: -3).sampleLatency - Self.ms(-5)) < 1e-12, "a negative value is off")
    }

    /// Chromium: ShouldHavePrediction.
    @Test func chromiumShouldHavePrediction() {
        var resampler = InputResampler()
        #expect(!resampler.hasPrediction)
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        #expect(!resampler.hasPrediction)
        #expect(resampler.resample(frameTime: Self.ms(16)) == nil)
        resampler.update(Self.sample(x: 0, y: 0, ms: 8))
        #expect(resampler.hasPrediction)
        resampler.reset()
        #expect(!resampler.hasPrediction)
    }

    /// Chromium: ResampleMinDelta.
    @Test func chromiumResampleMinDelta() {
        var resampler = InputResampler()
        #expect(!resampler.hasPrediction)
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 0, y: 0, ms: 1))
        #expect(!resampler.hasPrediction, "last dt < kResampleMinDelta")
        resampler.update(Self.sample(x: 0, y: 0, ms: 3))
        #expect(resampler.hasPrediction, "last dt >= kResampleMinDelta")
        resampler.update(Self.sample(x: 0, y: 0, ms: 15))
        #expect(resampler.hasPrediction)
        resampler.update(Self.sample(x: 0, y: 0, ms: 36))
        #expect(!resampler.hasPrediction, "reset when dt > kMaxTimeDelta")
    }

    /// Chromium: ResamplingValue. Sample times 33 - 5 = 28 ms and 41 - 5 = 36 ms.
    @Test func chromiumResamplingValue() {
        Self.validate(
            InputResampler(), x: [10, 20, 30], y: [5, 25, 35], t: [15, 24, 32],
            frameTimes: [33, 41], expectedX: [24.44, 35], expectedY: [33.89, 40]
        )
    }

    /// Chromium: ResamplingMaxPrediction. Frame 45 ms: the sample time is 30 + kResampleMaxPrediction = 38 ms.
    @Test func chromiumResamplingMaxPrediction() {
        Self.validate(
            InputResampler(), x: [10, 20], y: [5, 10], t: [10, 30],
            frameTimes: [45], expectedX: [24], expectedY: [12]
        )
    }

    /// Chromium: ResamplingBoundLastDelta. Frame 20 ms: the sample time is 14 + 50% of the last dt = 16 ms.
    @Test func chromiumResamplingBoundLastDelta() {
        Self.validate(
            InputResampler(), x: [10, 20], y: [5, 10], t: [10, 14],
            frameTimes: [20], expectedX: [22.5], expectedY: [11.25]
        )
    }

    /// Chromium: TimeInterval.
    @Test func chromiumTimeInterval() {
        var resampler = InputResampler()
        #expect(resampler.timeInterval == InputResampler.defaultTimeInterval)
        resampler.update(Self.sample(x: 10, y: 5, ms: 17))
        resampler.update(Self.sample(x: 20, y: 25, ms: 33))
        #expect(abs(resampler.timeInterval - Self.ms(33 - 17)) < 1e-12)
    }

    /// Chromium: ResamplingValueWithExperimentalLatencyFrameBased. 0.5 frame at 100 Hz is 5 ms ahead:
    /// sample time = frame time - 5 + 5.
    @Test func chromiumResamplingValueWithExperimentalLatencyFrameBased() {
        Self.validate(
            InputResampler(frameAheadMs: 0.5 * 10), x: [10, 20, 30], y: [5, 25, 35], t: [15, 24, 32],
            frameTimes: [28, 36], expectedX: [24.44, 35], expectedY: [33.89, 40]
        )
    }

    /// Chromium: ResamplingValueWithExperimentalLatencyFrameBasedSwitch. 1.0 frame at 200 Hz is 5 ms ahead.
    @Test func chromiumResamplingValueWithExperimentalLatencyFrameBasedSwitch() {
        Self.validate(
            InputResampler(frameAheadMs: 1.0 * 5), x: [10, 20, 30], y: [5, 25, 35], t: [15, 24, 32],
            frameTimes: [28, 36], expectedX: [24.44, 35], expectedY: [33.89, 40]
        )
    }

    /// cmux case: frame-ahead lifts the max-prediction cap, as Chromium does with the experiment on. The
    /// ResamplingMaxPrediction vectors with 5 ms ahead sample at 45 ms, not at the 38 ms cap.
    @Test func frameAheadLiftsTheMaxPredictionCap() {
        Self.validate(
            InputResampler(frameAheadMs: 5), x: [10, 20], y: [5, 10], t: [10, 30],
            frameTimes: [45], expectedX: [27.5], expectedY: [13.75]
        )
    }

    /// LinearResampling::Update: a gap over kMaxTimeDelta starts a new trajectory.
    @Test func aGapOverTwentyMillisecondsResets() {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 10))
        #expect(resampler.hasPrediction)
        resampler.update(Self.sample(x: 20, y: 0, ms: 31))
        #expect(!resampler.hasPrediction, "the 21 ms gap dropped the old trajectory")
        #expect(resampler.timeInterval == InputResampler.defaultTimeInterval)
        resampler.update(Self.sample(x: 24, y: 0, ms: 35))
        #expect(resampler.hasPrediction)
        #expect(abs(resampler.timeInterval - Self.ms(4)) < 1e-12)
    }

    @Test func resetForgetsEverySample() {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 8))
        resampler.reset()
        #expect(!resampler.hasPrediction)
        #expect(resampler == InputResampler(), "a reset resampler equals a new one")
    }

    /// cmux addition: no extrapolation across a direction change. Chromium would give x = 2.5 at 20 ms here.
    @Test func aDirectionChangeIsNotExtrapolated() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 8))
        resampler.update(Self.sample(x: 5, y: 0, ms: 16))
        let ahead = try #require(resampler.resample(frameTime: Self.ms(26)))
        Self.expect(ahead, x: 5, y: 0, ms: 16)

        let behind = try #require(resampler.resample(frameTime: Self.ms(18)))
        Self.expect(behind, x: 6.875, y: 0, ms: 13, "interpolation is unchanged by the addition")

        resampler.update(Self.sample(x: 0, y: 0, ms: 24))
        let resumed = try #require(resampler.resample(frameTime: Self.ms(34)))
        Self.expect(resumed, x: -2.5, y: 0, ms: 28, "a second step the same way extrapolates again")
    }

    @Test func aRightAngleTurnStillExtrapolates() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 8))
        resampler.update(Self.sample(x: 10, y: 10, ms: 16))
        let result = try #require(resampler.resample(frameTime: Self.ms(26)))
        Self.expect(result, x: 10, y: 15, ms: 20)
    }

    private static func ms(_ value: Double) -> Double { value / 1000 }

    private static func sample(x: Double, y: Double, ms value: Double) -> PointerSample {
        PointerSample(location: InputPoint(x: x, y: y), timestamp: ms(value))
    }

    /// Port of `InputPredictorTest::ValidatePredictor`: after each update that leaves a prediction, resample at the
    /// next frame time; the results must match in count and within `kEpsilon`.
    private static func validate(
        _ resampler: InputResampler, x: [Double], y: [Double], t: [Double],
        frameTimes: [Double], expectedX: [Double], expectedY: [Double],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var resampler = resampler
        var computed: [PointerSample] = []
        for index in t.indices {
            resampler.update(sample(x: x[index], y: y[index], ms: t[index]))
            guard resampler.hasPrediction else { continue }
            guard computed.count < frameTimes.count else {
                Issue.record("more predictions than frame times", sourceLocation: sourceLocation)
                return
            }
            let result = resampler.resample(frameTime: ms(frameTimes[computed.count]))
            #expect(result != nil, sourceLocation: sourceLocation)
            if let result { computed.append(result) }
        }
        #expect(computed.count == expectedX.count, sourceLocation: sourceLocation)
        for (index, result) in computed.enumerated() where index < expectedX.count {
            #expect(abs(result.location.x - expectedX[index]) < chromiumEpsilon, sourceLocation: sourceLocation)
            #expect(abs(result.location.y - expectedY[index]) < chromiumEpsilon, sourceLocation: sourceLocation)
        }
    }

    private static func expect(
        _ result: PointerSample, x: Double, y: Double, ms value: Double, _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(result.location.x - x) < 1e-9, comment, sourceLocation: sourceLocation)
        #expect(abs(result.location.y - y) < 1e-9, comment, sourceLocation: sourceLocation)
        #expect(abs(result.timestamp - ms(value)) < 1e-12, comment, sourceLocation: sourceLocation)
    }
}
