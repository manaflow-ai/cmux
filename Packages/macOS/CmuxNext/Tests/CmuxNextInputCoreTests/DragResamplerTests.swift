import CmuxNextInputCore
import Testing

/// DragResampler: a drag delivery's real point is always the newest OS sample, and its
/// drawn point is that pointer resampled at the frame's time with InputResampler (Chromium's
/// LinearResampling, `ui/base/prediction/linear_resampling.cc`).
struct DragResamplerTests {
    /// 1/256 s between samples: exact in binary, over kResampleMinDelta (2 ms), under kMaxTimeDelta (20 ms).
    static let step = 1.0 / 256

    /// A drag delivery of `xs` at `start + index * step` (every sample of a coalesced frame, newest last).
    static func delivery(_ xs: [Double], start: Double) throws -> PointerCoalescedInput {
        var input = try #require(PointerCoalescedInput(record(x: xs[0], at: start)))
        for (index, x) in xs.enumerated().dropFirst() {
            input.merge(record(x: x, at: start + Double(index) * step))
        }
        return input
    }

    static func record(x: Double, at time: Double) -> InputEventRecord {
        InputEventRecord(type: .leftMouseDragged, timestamp: time, windowNumber: 1, location: InputPoint(x: x, y: 0))
    }

    /// One sample gives no prediction: the drawn point is the real one.
    @Test func oneSampleDrawsTheRealPoint() throws {
        var resampler = DragResampler()
        let points = try resampler.points(for: Self.delivery([10], start: 1), at: PointerFrameTime(time: 1.01, interval: 1.0 / 120))
        #expect(points.realPoint == InputPoint(x: 10, y: 0))
        #expect(points.visualPoint == points.realPoint)
        #expect(points.realTime == 1)
    }

    /// A frame 5 ms after the newest sample's time + 5 ms (the resample latency) is past it: the drawn point
    /// extrapolates, capped at half the last interval (kResampleMaxPrediction does not bind at 3.9 ms).
    @Test func aLateFrameExtrapolatesHalfTheLastInterval() throws {
        var resampler = DragResampler()
        let start = 1.0
        let input = try Self.delivery([0, 10, 20, 30], start: start)
        let newest = start + 3 * Self.step
        let points = resampler.points(for: input, at: PointerFrameTime(time: newest + 0.020, interval: 1.0 / 120))
        #expect(points.realPoint == InputPoint(x: 30, y: 0), "decisions read the newest real sample")
        #expect(points.realTime == newest)
        #expect(abs(points.visualPoint.x - 35) < 1e-6, "half a step ahead: \(points.visualPoint.x)")
    }

    /// A frame whose time is the newest sample's interpolates 5 ms behind it (kResampleLatency), between the
    /// frame's own samples, so the drawn point lags the pointer instead of guessing.
    @Test func aFrameAtTheNewestSampleInterpolatesBehindIt() throws {
        var resampler = DragResampler()
        let start = 1.0
        let input = try Self.delivery([0, 10, 20, 30], start: start)
        let newest = start + 3 * Self.step
        let points = resampler.points(for: input, at: PointerFrameTime(time: newest, interval: 1.0 / 120))
        let expected = 30 + 10 * (-0.005 / Self.step)
        #expect(abs(points.visualPoint.x - expected) < 1e-6, "\(points.visualPoint.x) != \(expected)")
        #expect(points.visualPoint.x < 30)
        #expect(points.realPoint.x == 30)
    }

    /// Samples carry over between deliveries: a leading edge of one sample, then a frame of the rest.
    @Test func samplesCarryAcrossDeliveries() throws {
        var resampler = DragResampler()
        let start = 1.0
        _ = try resampler.points(for: Self.delivery([0], start: start), at: PointerFrameTime(time: start, interval: 1.0 / 120))
        let next = try #require(PointerCoalescedInput(Self.record(x: 10, at: start + Self.step)))
        let points = resampler.points(for: next, at: PointerFrameTime(time: start + Self.step + 0.020, interval: 1.0 / 120))
        #expect(abs(points.visualPoint.x - 15) < 1e-6, "the leading edge's sample is the segment's start")
    }

    /// A frame tick whose vsync time is older than the leading edge before it (main ran the tick late) resamples
    /// at the leading edge's time: the resample time never goes back, so the drawn point never steps back
    /// against the drag. Without the clamp the trailing frame draws 5 points behind the leading edge.
    @Test func aLateTickNeverDrawsBehindTheLeadingEdge() throws {
        var resampler = DragResampler()
        let start = 1.0
        let frame = { (time: Double) in PointerFrameTime(time: time, interval: 1.0 / 120) }
        _ = try resampler.points(for: Self.delivery([0, 10, 20], start: start), at: frame(start + 2 * Self.step))
        let leadTime = start + 3 * Self.step
        let leading = try resampler.points(for: Self.delivery([30], start: leadTime), at: frame(leadTime))
        // The tick's vsync came before the leading event, though main ran it after.
        let trailing = try resampler.points(for: Self.delivery([40, 50], start: start + 4 * Self.step), at: frame(start + 2.5 * Self.step))
        #expect(trailing.realPoint.x == 50)
        #expect(trailing.visualPoint.x >= leading.visualPoint.x - 1e-9,
                "the drawn point went back: \(leading.visualPoint.x) then \(trailing.visualPoint.x)")
        // A constant-speed drag resampled at the same time draws the same point.
        #expect(abs(trailing.visualPoint.x - leading.visualPoint.x) < 1e-9)
    }

    /// Frame-ahead is in milliseconds (InputResampler.frameAheadMs): 8 ms lifts the sample time from 5 ms behind
    /// the frame to 3 ms past it, with no cap on the extrapolation.
    @Test func frameAheadIsInMilliseconds() throws {
        let start = 1.0
        let input = try Self.delivery([0, 10, 20, 30], start: start)
        let newest = start + 3 * Self.step
        var ahead = DragResampler(frameAheadMs: 8)
        let points = ahead.points(for: input, at: PointerFrameTime(time: newest, interval: 1.0 / 120))
        let expected = 30 + 10 * (0.003 / Self.step)
        #expect(abs(points.visualPoint.x - expected) < 1e-6, "\(points.visualPoint.x) != \(expected)")
    }

    /// Debug frame-ahead prediction draws further ahead than the default; 0 is Chromium's default.
    @Test func frameAheadDrawsFurtherAhead() throws {
        let start = 1.0
        let input = try Self.delivery([0, 10, 20, 30], start: start)
        let frame = PointerFrameTime(time: start + 3 * Self.step, interval: 1.0 / 120)
        var plain = DragResampler()
        var ahead = DragResampler(frameAheadMs: 8)
        #expect(DragResampler(frameAheadMs: -3).frameAheadMs == 0)
        let aheadX = ahead.points(for: input, at: frame).visualPoint.x
        let plainX = plain.points(for: input, at: frame).visualPoint.x
        #expect(aheadX > plainX)
    }

    /// Reset forgets the drag: the next delivery has one sample again.
    @Test func resetForgetsTheDrag() throws {
        var resampler = DragResampler()
        let input = try Self.delivery([0, 10, 20], start: 1)
        _ = resampler.points(for: input, at: PointerFrameTime(time: 1.02, interval: 1.0 / 120))
        resampler.reset()
        let points = try resampler.points(for: Self.delivery([50], start: 1.1), at: PointerFrameTime(time: 1.12, interval: 1.0 / 120))
        #expect(points.visualPoint == InputPoint(x: 50, y: 0))
    }
}
