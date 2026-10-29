import CmuxNextLayout
import CoreGraphics
import Foundation
import Testing

/// The strip pan resampled at the frame's time (feature `stripPanResampling`): a frame shows the
/// gesture's offset between the two newest real samples or past the newest within Chromium's cap
/// (`ui/base/prediction/linear_resampling.cc`: 5 ms behind the frame, at most min(8 ms, dt / 2) ahead), and the
/// snap and the fling read the real samples only.
struct ColumnScrollReducerTests {
    /// Five 600 pt columns, 16 pt apart, in a 1000 pt viewport; focus on the first.
    private static func state(resamples: Bool) -> ColumnScrollState {
        let columns = (0..<5).map { index in
            ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: CGFloat(index) * 616, y: 0, width: 600, height: 800),
                               panes: [PaneID("p\(index)")])
        }
        var state = ColumnScrollState()
        state.reduce(.sync(ColumnStrip(columns: columns, viewportWidth: 1000, contentWidth: 5 * 616 - 16, gap: 16),
                           focused: PaneID("p0"), source: .programmatic, animated: false))
        state.resamplesPan = resamples
        state.reduce(.gestureBegan)
        return state
    }

    /// Three events 8 ms apart, each moving the strip 10 pt forward.
    private static func pan(_ state: inout ColumnScrollState, from start: TimeInterval = 10) {
        for step in 0..<3 {
            state.reduce(.gestureChanged(deltaX: -10, time: start + Double(step) * 0.008))
        }
    }

    @Test func aFrameShowsThePanBetweenTheTwoNewestSamples() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        Self.pan(&state)
        // The sample time is 10.019 - 0.005 = 10.014, a quarter of the last 8 ms segment before the newest sample.
        let shownPan = state.framePan(at: 10.019)
        let shown = try #require(shownPan)
        #expect(abs(shown - (base + 27.5)) < 0.001)
        #expect(shown >= base + 20 && shown <= base + 30)
        // The real offset stays the camera's.
        #expect(state.spring.value == base + 30)
        // A frame with no pan event since the last one shows nothing new.
        #expect(state.framePan(at: 10.027) == nil)
    }

    @Test func aLateFrameExtrapolatesNoFurtherThanTheCap() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        Self.pan(&state)
        state.reduce(.gestureChanged(deltaX: -10, time: 10.024))
        // 36 ms after the newest sample: capped at min(8 ms, 8 ms / 2) = 4 ms past it, half a segment of 10 pt.
        let shownPan = state.framePan(at: 10.060)
        let shown = try #require(shownPan)
        #expect(abs(shown - (base + 45)) < 0.001)
    }

    @Test func aFrameNeverShowsThePanBehindTheOlderSample() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        state.reduce(.gestureChanged(deltaX: -10, time: 10.000))
        state.reduce(.gestureChanged(deltaX: -10, time: 10.003))
        // The sample time 9.998 lies before both samples: the resampler would put the strip at base + 3.3.
        let shownPan = state.framePan(at: 10.003)
        let shown = try #require(shownPan)
        #expect(abs(shown - (base + 10)) < 0.001)
    }

    /// A frame that extrapolated past the newest sample, then a slower event: the next frame would interpolate
    /// behind what the strip showed although every event moved forward. As Chromium's
    /// `ScrollPredictor::ResampleEvent` zeroes a predicted delta against the event's, the strip holds instead.
    @Test func aDeceleratingEventNeverStepsTheStripBack() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        state.reduce(.gestureChanged(deltaX: -10, time: 10.000))
        state.reduce(.gestureChanged(deltaX: -10, time: 10.008))
        // Sample time 10.010, 2 ms (within the 4 ms cap) past the newest event: 2.5 pt ahead of it.
        let extrapolatedPan = state.framePan(at: 10.015)
        let extrapolated = try #require(extrapolatedPan)
        #expect(abs(extrapolated - (base + 22.5)) < 0.001)
        state.reduce(.gestureChanged(deltaX: -1, time: 10.016))
        // The resampler alone: 21 + 2.3 / 8 = 21.29, 1.2 pt behind the last frame.
        let nextPan = state.framePan(at: 10.0233)
        let next = try #require(nextPan)
        #expect(next >= extrapolated, "the strip stepped back from \(extrapolated) to \(next)")
        #expect(state.presentedPan == next)
    }

    /// Every presentation between frames shows what the last frame showed, not the real offset; the gesture's
    /// first event (shown in its own turn) is where the frames go on from.
    @Test func thePresentedPanStaysUntilTheNextFrame() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        #expect(state.presentedPan == nil, "no frame showed the gesture yet")
        state.reduce(.gestureChanged(deltaX: -10, time: 10.000))
        state.panShownUnresampled()
        #expect(state.presentedPan == base + 10)
        #expect(state.framePan(at: 10.004) == nil, "the first event already showed")
        state.reduce(.gestureChanged(deltaX: -10, time: 10.008))
        state.reduce(.gestureChanged(deltaX: -10, time: 10.016))
        let shownPan = state.framePan(at: 10.019)
        let shown = try #require(shownPan)
        #expect(state.framePan(at: 10.027) == nil)
        #expect(state.presentedPan == shown && shown < state.spring.value)
    }

    @Test func withoutResamplingOrAFrameTimeAFrameShowsTheRealOffset() throws {
        var off = Self.state(resamples: false)
        Self.pan(&off)
        let offPan = off.framePan(at: 10.019)
        #expect(try #require(offPan) == off.spring.value)

        var on = Self.state(resamples: true)
        Self.pan(&on)
        let onPan = on.framePan(at: nil)
        #expect(try #require(onPan) == on.spring.value)
    }

    @Test func theFirstEventShowsTheRealOffset() throws {
        var state = Self.state(resamples: true)
        let base = state.spring.value
        state.reduce(.gestureChanged(deltaX: -10, time: 10))
        // One sample is no trajectory yet.
        let framed = state.framePan(at: 10.004)
        #expect(try #require(framed) == base + 10)
    }

    @Test func theFlingIsTheSameWithAndWithoutResampling() {
        var off = Self.state(resamples: false)
        var on = Self.state(resamples: true)
        Self.pan(&off)
        for step in 0..<3 {
            on.reduce(.gestureChanged(deltaX: -10, time: 10 + Double(step) * 0.008))
            _ = on.framePan(at: 10.003 + Double(step) * 0.008)
        }
        let offEffects = off.reduce(.gestureEnded(time: 10.020, animated: true))
        let onEffects = on.reduce(.gestureEnded(time: 10.020, animated: true))
        #expect(onEffects == offEffects)
        #expect(on.spring == off.spring)
        #expect(on.spring.velocity != 0)
        // No gesture: no frame pan.
        #expect(on.framePan(at: 10.030) == nil)
    }
}
