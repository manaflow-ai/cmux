@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// The summary `debug.page {action: frames}` gives a bench (perf-lead row 23): a page at the full
/// rate of a 120 Hz display shows no long frames, a page held near 60 shows every interval long.
struct PageFrameCadenceTests {
    @Test func fullRateOn120HzHasNoLongFrames() {
        let cadence = PageFrameCadence(intervalsMs: Array(repeating: 8.33, count: 119), windowMs: 1000, displayFPS: 120)
        #expect(cadence.longFrames == 0)
        #expect(cadence.percentileMs(0.95) == 8.33)
        #expect(abs((cadence.observedFPS ?? 0) - 120) < 0.5)
    }

    @Test func near60On120HzMakesEveryIntervalLong() {
        let cadence = PageFrameCadence(intervalsMs: Array(repeating: 16.67, count: 59), windowMs: 1000, displayFPS: 120)
        #expect(cadence.longFrames == 59)
        #expect(abs((cadence.observedFPS ?? 0) - 60) < 0.5)
    }

    @Test func percentilesUseNearestRank() {
        let cadence = PageFrameCadence(intervalsMs: [8, 9, 10, 11, 50], windowMs: 1000, displayFPS: 120)
        #expect(cadence.percentileMs(0.5) == 10)
        #expect(cadence.percentileMs(0.95) == 50)
        #expect(cadence.longFrames == 1)
    }

    @Test func aPageThatRenderedNothingReportsNoFrames() {
        let cadence = PageFrameCadence(intervalsMs: [], windowMs: 1000, displayFPS: nil)
        #expect(cadence.percentileMs(0.95) == nil)
        #expect(cadence.observedFPS == nil)
        #expect(cadence.longFrames == 0)
        #expect(cadence.json["frames"] == .number(0))
        #expect(cadence.json["p95_ms"] == .null)
    }
}
