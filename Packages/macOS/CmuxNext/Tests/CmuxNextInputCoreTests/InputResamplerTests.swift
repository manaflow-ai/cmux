import CmuxNextInputCore
import Testing

/// InputResampler against Chromium's LinearResampling (p04-input-039). The cases port
/// `ui/base/prediction/linear_resampling_unittest.cc` (ShouldHavePrediction, ResamplingValue,
/// ResamplingMaxPrediction, ResamplingBoundLastDelta, TimeInterval) with values worked from the same formulas;
/// the direction-change cases test the one cmux addition, which Chromium does not have.
struct InputResamplerTests {
    @Test func chromiumConstants() {
        #expect(InputResampler.resampleLatency == -0.005)
        #expect(InputResampler.maxPrediction == 0.008)
        #expect(InputResampler.minDelta == 0.002)
        #expect(InputResampler.maxTimeDelta == 0.020)
        #expect(InputResampler.defaultTimeInterval == 0.008)
        #expect(InputResampler().frameAhead == 0, "frame-ahead prediction is off by default, as in Chromium")
    }

    /// Chromium: ShouldHavePrediction. Two samples are needed, at least kResampleMinDelta apart.
    @Test func shouldHavePrediction() {
        var resampler = InputResampler()
        #expect(!resampler.hasPrediction)
        resampler.update(Self.sample(x: 1, y: 1, ms: 0))
        #expect(!resampler.hasPrediction)
        #expect(resampler.resample(frameTime: Self.ms(16), frameInterval: Self.ms(16)) == nil)
        resampler.update(Self.sample(x: 1, y: 1, ms: 5))
        #expect(resampler.hasPrediction)
        resampler.update(Self.sample(x: 1, y: 1, ms: 6))
        #expect(!resampler.hasPrediction, "1 ms is under kResampleMinDelta")
        #expect(resampler.resample(frameTime: Self.ms(16), frameInterval: Self.ms(16)) == nil)
        resampler.update(Self.sample(x: 1, y: 1, ms: 8))
        #expect(resampler.hasPrediction, "2 ms is kResampleMinDelta exactly")
    }

    /// Chromium: ResamplingValue. The sample time is frame time - 5 ms, between the two newest samples.
    @Test func resamplingValueInterpolatesFiveMillisecondsBehindTheFrame() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 10, y: 5, ms: 15))
        resampler.update(Self.sample(x: 20, y: 25, ms: 24))
        let first = try #require(resampler.resample(frameTime: Self.ms(24), frameInterval: Self.ms(16)))
        Self.expect(first, x: 10 + 10 * 4.0 / 9.0, y: 5 + 20 * 4.0 / 9.0, ms: 19)

        resampler.update(Self.sample(x: 30, y: 35, ms: 32))
        let second = try #require(resampler.resample(frameTime: Self.ms(32), frameInterval: Self.ms(16)))
        Self.expect(second, x: 23.75, y: 28.75, ms: 27)
    }

    /// Chromium: ResamplingMaxPrediction. Extrapolation stops kResampleMaxPrediction (8 ms) past the newest sample.
    @Test func extrapolationIsCappedAtEightMilliseconds() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 20, y: 10, ms: 20))
        #expect(resampler.hasPrediction, "a 20 ms gap is kMaxTimeDelta exactly and does not reset")
        let result = try #require(resampler.resample(frameTime: Self.ms(40), frameInterval: Self.ms(16)))
        Self.expect(result, x: 28, y: 14, ms: 28)
    }

    /// Chromium: ResamplingBoundLastDelta. Extrapolation stops at half the last dt when that is under 8 ms.
    @Test func extrapolationIsCappedAtHalfTheLastDelta() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 10, ms: 10))
        let result = try #require(resampler.resample(frameTime: Self.ms(30), frameInterval: Self.ms(16)))
        Self.expect(result, x: 15, y: 15, ms: 15)
    }

    /// Chromium: TimeInterval. The last dt, or kTimeInterval before two samples.
    @Test func timeIntervalIsTheLastDeltaOrTheDefault() {
        var resampler = InputResampler()
        #expect(resampler.timeInterval == InputResampler.defaultTimeInterval)
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        #expect(resampler.timeInterval == InputResampler.defaultTimeInterval)
        resampler.update(Self.sample(x: 1, y: 0, ms: 5))
        #expect(abs(resampler.timeInterval - Self.ms(5)) < 1e-12)
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
        let ahead = try #require(resampler.resample(frameTime: Self.ms(26), frameInterval: Self.ms(16)))
        Self.expect(ahead, x: 5, y: 0, ms: 16)

        let behind = try #require(resampler.resample(frameTime: Self.ms(18), frameInterval: Self.ms(16)))
        Self.expect(behind, x: 6.875, y: 0, ms: 13, "interpolation is unchanged by the addition")

        resampler.update(Self.sample(x: 0, y: 0, ms: 24))
        let resumed = try #require(resampler.resample(frameTime: Self.ms(34), frameInterval: Self.ms(16)))
        Self.expect(resumed, x: -2.5, y: 0, ms: 28, "a second step the same way extrapolates again")
    }

    @Test func aRightAngleTurnStillExtrapolates() throws {
        var resampler = InputResampler()
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 8))
        resampler.update(Self.sample(x: 10, y: 10, ms: 16))
        let result = try #require(resampler.resample(frameTime: Self.ms(26), frameInterval: Self.ms(16)))
        Self.expect(result, x: 10, y: 15, ms: 20)
    }

    /// Chromium's kResamplingScrollEventsExperimentalPrediction frames-based mode: sample time =
    /// frame time + frameAhead x interval - 5 ms, with no max-prediction cap.
    @Test func frameAheadPredictsPastTheCap() throws {
        var resampler = InputResampler(frameAhead: 0.5)
        resampler.update(Self.sample(x: 0, y: 0, ms: 0))
        resampler.update(Self.sample(x: 10, y: 0, ms: 10))
        let interval = 1.0 / 60.0
        let result = try #require(resampler.resample(frameTime: Self.ms(20), frameInterval: interval))
        let sampleMs = 20 + 500 * interval - 5
        Self.expect(result, x: sampleMs, y: 0, ms: sampleMs)

        resampler.frameAhead = 0
        let capped = try #require(resampler.resample(frameTime: Self.ms(20), frameInterval: interval))
        Self.expect(capped, x: 15, y: 0, ms: 15)
    }

    private static func ms(_ value: Double) -> Double { value / 1000 }

    private static func sample(x: Double, y: Double, ms value: Double) -> PointerSample {
        PointerSample(location: InputPoint(x: x, y: y), timestamp: ms(value))
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
