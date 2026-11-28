@testable import CmuxTabsKit
import Testing

struct ZoomFrameLogTests {
    @Test func countsLongFramesFromTheTap() {
        var log = ZoomFrameLog()
        log.begin(at: 10, toOverview: true)
        // Tap to first frame 30 ms (a hitch), then 120 Hz frames, one missed.
        var t = 10.030
        log.frame(at: t)
        for i in 0..<20 {
            t += i == 7 ? 2.0 / 120 : 1.0 / 120
            log.frame(at: t)
        }
        let summary = log.end(maxFPS: 120)
        let s = try! #require(summary)
        #expect(s.toOverview && s.frames == 21)
        #expect(abs(s.firstFrameMs - 30) < 0.01 && abs(s.worstMs - 30) < 0.01)
        #expect(s.over8ms == 2 && s.over16ms == 1)
        #expect(s.slow == [ZoomFrameLog.Slow(frame: 0, ms: 30, progress: 0)])
        let again = log.end(maxFPS: 120)
        #expect(!log.isRunning && again == nil)
    }
}
